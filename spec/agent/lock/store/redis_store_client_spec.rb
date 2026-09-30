# frozen_string_literal: true

require "redis"

# How the Redis store finds its server: REDIS_URL first when it is set, the
# local default next, and nothing when neither answers. Against doubles rather
# than a live server, because the point is the order of the attempts and what
# a refusal does to it, not whether Redis works.
RSpec.describe Agent::Lock::Store::RedisStore do
  let(:configured) { "redis://shared.example.test:6379/3" }
  let(:local) { described_class::LOCAL_URL }
  let(:refused) { Redis::CannotConnectError.new("refused") }

  def answering
    instance_double(Redis, info: { "redis_version" => "8.0.0" })
  end

  def redis_at(url, client)
    allow(Redis).to receive(:new).with(url: url).and_return(client)
  end

  def redis_refusing(url)
    allow(Redis).to receive(:new).with(url: url).and_raise(refused)
  end

  # Only the two candidate URLs are faked. Anything else, such as the suite's
  # own after-example flush against TEST_REDIS_URL, still reaches a real client.
  before do
    described_class.reset!
    allow(Redis).to receive(:new).and_call_original
  end

  after { described_class.reset! }

  describe ".candidate_urls" do
    it "tries REDIS_URL and then the local default when REDIS_URL is set" do
      with_env("REDIS_URL" => configured) do
        expect(described_class.candidate_urls).to eq([configured, local])
      end
    end

    it "tries only the local default when REDIS_URL is unset" do
      with_env("REDIS_URL" => nil) do
        expect(described_class.candidate_urls).to eq([local])
      end
    end

    it "treats a blank REDIS_URL as unset" do
      with_env("REDIS_URL" => "  ") do
        expect(described_class.candidate_urls).to eq([local])
      end
    end

    it "does not try the same server twice when REDIS_URL names the local default" do
      with_env("REDIS_URL" => local) do
        expect(described_class.candidate_urls).to eq([local])
      end
    end
  end

  describe ".create_client" do
    it "uses REDIS_URL when it answers, without probing the local default" do
      shared = answering
      redis_at(configured, shared)

      with_env("REDIS_URL" => configured) do
        client, error = described_class.create_client

        aggregate_failures do
          expect(client).to be(shared)
          expect(error).to be_nil
          expect(described_class.url).to eq(configured)
          expect(Redis).not_to have_received(:new).with(url: local)
        end
      end
    end

    it "falls back to the local default when REDIS_URL refuses" do
      nearby = answering
      redis_refusing(configured)
      redis_at(local, nearby)

      with_env("REDIS_URL" => configured) do
        client, error = described_class.create_client

        aggregate_failures do
          expect(client).to be(nearby)
          expect(error).to be_nil
          expect(described_class.url).to eq(local)
        end
      end
    end

    it "reports the last error when neither answers" do
      redis_refusing(configured)
      redis_refusing(local)

      with_env("REDIS_URL" => configured) do
        client, error = described_class.create_client

        aggregate_failures do
          expect(client).to be_nil
          expect(error).to be(refused)
        end
      end
    end

    it "does not probe again once a client is established" do
      redis_at(local, answering)

      with_env("REDIS_URL" => nil) do
        described_class.create_client
        described_class.create_client

        expect(Redis).to have_received(:new).once
      end
    end
  end

  describe ".for" do
    it "lands on the file store when neither Redis answers" do
      redis_refusing(configured)
      redis_refusing(local)

      with_env("REDIS_URL" => configured) do
        expect(Agent::Lock::Store.default_backend).to eq("file")
      end
    end
  end
end
