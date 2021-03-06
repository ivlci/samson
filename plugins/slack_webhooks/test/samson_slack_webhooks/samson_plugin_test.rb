# frozen_string_literal: true
require_relative '../test_helper'

SingleCov.covered!

describe SamsonSlackWebhooks do
  let(:deploy) { deploys(:succeeded_test) }
  let(:stage) { deploy.stage }
  let!(:webhook) { stage.slack_webhooks.build(before_deploy: true, after_deploy: true, buddy_request: true) }

  describe :buddy_request do
    it "sends notification" do
      SlackWebhookNotification.any_instance.expects(:deliver)
      Samson::Hooks.fire(:buddy_request, deploy)
    end

    describe "when disabled" do
      before { webhook.buddy_request = false }

      it "does not send notifications when disabled" do
        SlackWebhookNotification.any_instance.expects(:deliver).never
        Samson::Hooks.fire(:buddy_request, deploy)
      end

      # using full http test here to make sure our hackery works
      it "sends global hook when configured" do
        with_env SLACK_GLOBAL_BUDDY_REQUEST: 'http://foo.com/baz#bar' do
          stub_request(:post, "http://foo.com/baz").with do |x|
            x.body.must_include "channel%22%3A%22bar"
          end
          Samson::Hooks.fire(:buddy_request, deploy)
        end
      end
    end
  end

  describe :before_deploy do
    it "sends notification on before hook" do
      SlackWebhookNotification.any_instance.expects(:deliver)
      Samson::Hooks.fire(:before_deploy, deploy, nil)
    end

    it "does not send notifications when disabled" do
      webhook.before_deploy = false
      SlackWebhookNotification.any_instance.expects(:deliver).never
      Samson::Hooks.fire(:before_deploy, deploy, nil)
    end
  end

  describe :after_deploy do
    it "sends notification on after hook" do
      SlackWebhookNotification.any_instance.expects(:deliver)
      Samson::Hooks.fire(:after_deploy, deploy, nil)
    end

    it "does not send notifications when disabled" do
      webhook.after_deploy = false
      SlackWebhookNotification.any_instance.expects(:deliver).never
      Samson::Hooks.fire(:after_deploy, deploy, nil)
    end
  end

  describe :stage_clone do
    it "copies all attributes except id" do
      stage.slack_webhooks = [SlackWebhook.new(webhook_url: 'http://example.com', after_deploy: true)]
      new_stage = Stage.new
      Samson::Hooks.fire(:stage_clone, stage, new_stage)
      new_stage.slack_webhooks.map(&:attributes).must_equal [{
        "id" => nil,
        "webhook_url" => "http://example.com",
        "channel" => nil,
        "stage_id" => nil,
        "created_at" => nil,
        "updated_at" => nil,
        "buddy_request" => false,
        "before_deploy" => false,
        "after_deploy" => true,
        "buddy_box" => false,
        "only_on_failure" => false
      }]
    end
  end

  describe :stage_permitted_params do
    it "includes our params" do
      Samson::Hooks.fire(:stage_permitted_params).must_include(
        slack_webhooks_attributes: [
          :id, :_destroy,
          :webhook_url, :channel,
          :buddy_box, :buddy_request, :before_deploy, :after_deploy, :only_on_failure
        ]
      )
    end
  end
end
