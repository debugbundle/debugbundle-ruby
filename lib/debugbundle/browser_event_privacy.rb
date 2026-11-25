# frozen_string_literal: true

require 'uri'
require 'debugbundle/evidence_value'
require 'debugbundle/evidence_wire'
require 'debugbundle/telemetry_privacy'

module DebugBundle
  # Schema-aware privacy helpers for closed browser event and rejection structures.
  module BrowserEventPrivacy
    ALLOWED_HTML_RESOURCE_TAGS = %w[script link img audio video source iframe object embed input].freeze
    ALLOWED_READY_STATES = %w[loading interactive complete].freeze
    ALLOWED_VISIBILITY_STATES = %w[visible hidden prerender unloaded].freeze
    ALLOWED_REJECTION_KINDS = %w[error string object null undefined unknown].freeze
    BROWSER_EVENT_REQUIRED = %w[kind message file_name line_number column_number target opaque].freeze
    BROWSER_EVENT_OPTIONAL = %w[page].freeze
    TARGET_REQUIRED = %w[tag_name source_url].freeze
    TARGET_OPTIONAL = %w[attributes].freeze
    TARGET_ATTR_STRINGS = %w[rel as type media cross_origin].freeze
    TARGET_ATTR_BOOLS = %w[async defer integrity_present].freeze
    TARGET_ATTR_KEYS = (TARGET_ATTR_STRINGS + TARGET_ATTR_BOOLS).freeze
    PAGE_REQUIRED = %w[url referrer ready_state visibility_state].freeze
    REJECTION_REQUIRED = %w[kind].freeze
    REJECTION_OPTIONAL = %w[name message preview].freeze
    MAX_SAFE_INT = 9_007_199_254_740_991

    module_function

    def scrub_string(value, opts)
      protected = TelemetryPrivacy.protect(value, **opts)
      protected.is_a?(String) ? protected : nil
    end

    def scrub_nullable_string(value, opts)
      return [true, nil] if value.nil?
      return [false, nil] unless value.is_a?(String)

      scrubbed = scrub_string(value, opts)
      scrubbed.nil? ? [false, nil] : [true, scrubbed]
    end

    def sanitize_browser_stack_urls(text)
      return text unless text.match?(%r{https?://}i)

      text.gsub(%r{https?://[^\s]+}i) do |source|
        suffix = source[/:\d+(?::\d+)?[),]*\z/] || source[/[),]+\z/] || ''
        location = suffix.empty? ? source : source[0, source.length - suffix.length]
        strip_stack_url(location, suffix)
      end
    end

    def strip_stack_url(location, suffix)
      ascii = location.gsub(/[^\x00-\x7f]/) { |char| char.bytes.map { |byte| format('%%%02X', byte) }.join }
      uri = URI.parse(ascii)
      return "[unavailable-url]#{suffix}" unless uri.scheme && uri.host

      port = uri.port && uri.port != uri.default_port ? ":#{uri.port}" : ''
      path = uri.path.empty? ? '/' : uri.path
      "#{uri.scheme}://#{uri.host}#{port}#{path}#{suffix}"
    rescue URI::InvalidURIError
      "[unavailable-url]#{suffix}"
    end

    def sanitize_browser_event(raw, opts)
      owned = EvidenceValue.copy(raw)
      return :invalid if owned.equal?(EvidenceValue::INVALID)
      return nil unless valid_browser_event_header?(owned)

      ok_msg, msg = scrub_nullable_string(owned['message'], opts)
      ok_file, file_name = scrub_nullable_string(owned['file_name'], opts)
      return nil unless ok_msg && ok_file

      target_out = owned['target'].nil? ? nil : sanitize_target(owned['target'], opts)
      return nil if !owned['target'].nil? && target_out.nil?

      out = {
        'kind' => owned['kind'], 'message' => msg, 'file_name' => file_name,
        'line_number' => owned['line_number'], 'column_number' => owned['column_number'],
        'target' => target_out, 'opaque' => owned['opaque']
      }
      if owned.key?('page')
        page_out = sanitize_page(owned['page'], opts)
        return nil unless page_out

        out['page'] = page_out
      end
      out
    end

    def valid_browser_event_header?(owned)
      EvidenceWire.closed(owned, BROWSER_EVENT_REQUIRED, BROWSER_EVENT_OPTIONAL) &&
        %w[window_error resource_error].include?(owned['kind']) &&
        [true, false].include?(owned['opaque']) &&
        (owned['line_number'].nil? || EvidenceWire.integer(owned['line_number'], 0, MAX_SAFE_INT)) &&
        (owned['column_number'].nil? || EvidenceWire.integer(owned['column_number'], 0, MAX_SAFE_INT))
    end

    def sanitize_target(raw_target, opts)
      return nil unless EvidenceWire.closed(raw_target, TARGET_REQUIRED, TARGET_OPTIONAL)

      ok_tag, tag_name = sanitize_target_tag_name(raw_target['tag_name'], opts)
      ok_src, source_url = scrub_nullable_string(raw_target['source_url'], opts)
      return nil unless ok_tag && ok_src

      out = { 'tag_name' => tag_name, 'source_url' => source_url }
      if raw_target.key?('attributes')
        attrs = sanitize_target_attributes(raw_target['attributes'], opts)
        return nil unless attrs

        out['attributes'] = attrs
      end
      out
    end

    def sanitize_target_tag_name(raw_tag_name, opts)
      return [true, nil] if raw_tag_name.nil?
      return [false, nil] unless raw_tag_name.is_a?(String)
      return [true, raw_tag_name] if ALLOWED_HTML_RESOURCE_TAGS.include?(raw_tag_name.downcase(:ascii))

      sanitized = TelemetryPrivacy.protect({ 'tag_name' => raw_tag_name }, **opts)
      return [false, nil] unless sanitized.is_a?(Hash) && sanitized['tag_name'].is_a?(String)

      [true, sanitized['tag_name']]
    end

    def sanitize_target_attributes(raw_attrs, opts)
      return nil unless EvidenceWire.closed(raw_attrs, [], TARGET_ATTR_KEYS)

      out = {}
      TARGET_ATTR_STRINGS.each do |key|
        next unless raw_attrs.key?(key)
        return nil unless raw_attrs[key].is_a?(String)

        scrubbed = scrub_string(raw_attrs[key], opts)
        return nil unless scrubbed

        out[key] = scrubbed
      end
      TARGET_ATTR_BOOLS.each do |key|
        next unless raw_attrs.key?(key)
        return nil unless [true, false].include?(raw_attrs[key])

        out[key] = raw_attrs[key]
      end
      out
    end

    def sanitize_page(raw_page, opts)
      return nil unless EvidenceWire.closed(raw_page, PAGE_REQUIRED)

      ok_url, url = scrub_nullable_string(raw_page['url'], opts)
      ok_ref, referrer = scrub_nullable_string(raw_page['referrer'], opts)
      ready_state = raw_page['ready_state']
      visibility_state = raw_page['visibility_state']
      return nil unless ok_url && ok_ref
      return nil unless ready_state.nil? || ALLOWED_READY_STATES.include?(ready_state)
      return nil unless visibility_state.nil? || ALLOWED_VISIBILITY_STATES.include?(visibility_state)

      { 'url' => url, 'referrer' => referrer, 'ready_state' => ready_state, 'visibility_state' => visibility_state }
    end

    def sanitize_rejection_reason(raw, opts)
      owned = EvidenceValue.copy(raw)
      return :invalid if owned.equal?(EvidenceValue::INVALID)
      return nil unless EvidenceWire.closed(owned, REJECTION_REQUIRED, REJECTION_OPTIONAL)
      return nil unless ALLOWED_REJECTION_KINDS.include?(owned['kind'])

      out = { 'kind' => owned['kind'] }
      REJECTION_OPTIONAL.each do |field|
        next unless owned.key?(field)
        return nil unless owned[field].is_a?(String)

        scrubbed = scrub_string(owned[field], opts)
        return nil unless scrubbed

        out[field] = scrubbed
      end
      out
    end
  end
end
