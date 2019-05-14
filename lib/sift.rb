require 'excon'
require 'json'

class Sift
  TopicMap = {
    0 => 'general',
    1 => 'bullying',
    2 => 'fighting',
    3 => 'pii',
    4 => 'sexting',
    5 => 'vulgar',
    6 => 'drugs',
    7 => 'items',
    8 => 'alarm',
    9 => 'fraud',
    10 => 'hate',
    11 => 'religious',
    13 => 'website',
    14 => 'grooming',
    15 => 'threats',
    16 => 'realname',
    17 => 'radicalization',
    18 => 'subversive',
    19 => 'sentiment'
  }

  class Error < StandardError; end

  class Risk
    attr_reader :risk, :response, :raw_response

    def initialize(risk:, response:, topic_hash:, raw_response:)
      @risk = risk,
      @response = response
      @topic_hash = topic_hash
      @raw_response = raw_response
    end

    def over_any_max_risk
      @topic_hash.any? do |topic_id, risk|
        topic_name = TopicMap[topic_id.to_i]
        next if topic_name.nil?

        site_setting_name = "sift_#{topic_name}_deny_level"
        max_risk = SiteSetting.send(site_setting_name)
        !max_risk.nil? && risk.to_i > max_risk.to_i
      end
    end

    def topic_string
      # Return a string with the topics and risk level enumerated
      # Simple way to output classification
      @topic_hash.reduce('') do |acc, (topic_id, risk)|
        topic_name = TopicMap[topic_id.to_i]
        next(acc) if topic_name.nil?

        acc << " #{topic_name}: #{risk.to_i}"
      end
    end
  end

  class Client

    def initialize()
      @base_url = Discourse.base_url
      @api_key = SiteSetting.sift_api_key
      @api_url = SiteSetting.sift_api_url
      @end_point = SiteSetting.sift_end_point
      @post_action_end_point = SiteSetting.sift_action_end_point

    end

    def self.with_client()
      client = self.new
      yield client if block_given?
    end

    def submit_for_classification(to_classify)
      #Rails.logger.error("sift_debug: submit_for_classification Enter")
      response = post_classification(@end_point, to_classify)

      #Rails.logger.error("sift_debug: #{response.inspect}")
      if response.nil? || response.status != 200
        #if there is an error reaching Community Sift, escalate to human moderation

        Rails.logger.error("sift_debug: Got an error from Sift: status: #{response.status} response: #{response.inspect}")

        # Setting determines if the response is treated as a
        # classification failure
        if SiteSetting.sift_error_is_false_response
          classification_answer = false
        else
          classification_answer = true
        end

        data = {
          'risk' => 0,
          'response' => classification_answer,
          'topics' => {}
        }.to_json
        response = Excon::Response.new(body: data)
      end

      sift_response = JSON.parse(response.body)

      #Rails.logger.error("sift_debug: Before response custom fields save #{payload.custom_fields.inspect}")
      to_classify.custom_fields[DiscourseSift::RESPONSE_CUSTOM_FIELD] = sift_response
      to_classify.save_custom_fields(true)
      #Rails.logger.error("sift_debug: After response custom fields save #{payload.custom_fields.inspect}")

      #Rails.logger.error("sift_debug: Before validate...")

      validate_classification(sift_response)

    end

    def submit_for_post_action(reviewable, reason)

      Rails.logger.debug("sift_debug: submit_for_post_action Enter")

      Rails.logger.debug("sift_debug: submit_for_post_action: self='#{reviewable.inspect}', reason='#{reason}'")

      the_post = reviewable.target


      payload = {
        'text' => "#{the_post.raw.strip[0..30999]}",
        'reason' => reason
      }

      response = post(@post_action_end_point, payload)

    end

      private

    def validate_classification(sift_response)
      # TODO: Handle errors better?  Currently any issues with connection including incorrect API key leads to
      #       every post needing moderation

      Rails.logger.debug("sift_debug: response = #{sift_response.inspect}")

      hash_topics = sift_response.fetch('topics', {})
      hash_topics.default = 0

      Sift::Risk.new(
        risk: sift_response.fetch('risk', 0).to_i,
        response: sift_response.fetch('response', false),
        topic_hash: hash_topics,
        raw_response: sift_response
      )
    end

    def post_classification(target, to_classify)
      # Assume topic_id and player_id are no more than 1000 chars
      # Send a maximum of 31000 chars which is the default for
      # maximum post length site settings.
      #

      request_text = "#{to_classify.raw.strip[0..30999]}"
      # If this is the first post, also classify the Topic title
      # TODO: Is this the best way to check for a new/editied topic?
      #   Testing shows that the post is always post_number 1 for new
      #   topics, and edits just to Title of topic also pass the post here
      # TODO: Should title be classified separately rather than pre-pending
      #   to the post text?
      if to_classify.is_first_post?
        request_text = "#{to_classify.topic.title} #{request_text}"
      end

      #Rails.logger.debug("sift_debug: payload = #{payload.inspect}")

      payload = {
        'category' => "#{to_classify.topic&.category&.id}",
        'subcategory' => "#{to_classify.topic&.id}",
        'user_id' => "#{to_classify.user.id}",
        'user_display_name' => "#{to_classify.user.username}",
        'content_id' => "#{to_classify.id}",
        'text' => request_text
      }

      # If the site is configured with a fixed language code
      # then include that in request
      if !SiteSetting.sift_language_code.blank?
        payload['language'] = SiteSetting.sift_language_code

      end

      Rails.logger.debug("sift_debug: post_classification: payload = #{payload.inspect}")

      # TODO: Need to handle errors (e.g. incorrect API key)

      # Call Sift
      post(target, payload)

    end

    def post(url_path, payload)
      # send a request to a sift path

      Rails.logger.debug("sift_debug: post: payload = #{payload.inspect}")

      # Account for a '/' or not at start of endpoint
      if !url_path.start_with? '/'
        url_path = "/#{url_path}"
      end

      request_url = "#{@api_url}#{url_path}"
      request_body = payload

      request_body = request_body.to_json
      Rails.logger.debug("sift_debug: post: request_body = #{request_body.inspect}")

      # TODO: Need to handle errors (e.g. incorrect API key)

      #Rails.logger.debug("sift_debug: post: request_body = #{request_body.inspect}")

      begin
        Excon.post(
          request_url,
          body: request_body,
          headers: { 'Content-Type' => 'application/json' },
          user: 'discourse-plugin',
          password: @api_key
        )
      rescue
        nil
      end
    end

  end


end
