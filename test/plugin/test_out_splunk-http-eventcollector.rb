require 'helper'

class SplunkHTTPEventcollectorOutputTest < Test::Unit::TestCase
  def setup
    Fluent::Test.setup
  end

  CONFIG = %[
    server localhost:8089
    verify false
    token changeme
  ]
  TIME_OBJ = Time.parse("2010-01-02 13:14:15 UTC")

  def create_driver(conf=CONFIG, tag='test')
    Fluent::Test::BufferedOutputTestDriver.new(Fluent::SplunkHTTPEventcollectorOutput, tag).configure(conf)
  end

  def test_configure
    # default
    d = create_driver
    assert_equal nil, d.instance.source
    assert_equal 'fluentd', d.instance.sourcetype
  end

  def test_write
    [TIME_OBJ.to_i, TIME_OBJ.to_f].each do |time|
      stub_request(:post, "https://localhost:8089/services/collector/event").
        to_return(body: '{"text":"Success","code":0}')

      d = create_driver

      d.emit({ "message" => "a message"}, time)

      d.run

      assert_requested :post, "https://localhost:8089/services/collector/event",
        headers: {
          "Authorization" => "Splunk changeme",
          'Content-Type' => 'application/json',
          'User-Agent' => 'fluent-plugin-splunk-http-eventcollector/0.0.1'
        },
        body: { time: time, source:"test", sourcetype: "fluentd", host: "", index: "main", event: "a message" },
        times: (case time when Integer then 1 when Float then 2 end)
    end
  end

  def test_expand
    [TIME_OBJ.to_i, TIME_OBJ.to_f].each do |time|
      stub_request(:post, "https://localhost:8089/services/collector/event").
        to_return(body: '{"text":"Success","code":0}')

      d = create_driver(CONFIG + %[
        source ${record["source"]}
        sourcetype ${tag_parts[0]}
      ])

      d.emit({"message" => "a message", "source" => "source-from-record"}, time)

      d.run

      assert_requested :post, "https://localhost:8089/services/collector/event",
        headers: {"Authorization" => "Splunk changeme"},
        body: { time: time, source: "source-from-record", sourcetype: "test", host: "", index: "main", event: "a message" },
        times: (case time when Integer then 1 when Float then 2 end)
    end
  end

  def test_4XX_error_retry
    [TIME_OBJ.to_i, TIME_OBJ.to_f].each do |time|
      stub_request(:post, "https://localhost:8089/services/collector/event").
        with(headers: {"Authorization" => "Splunk changeme"}).
        to_return(body: '{"text":"Incorrect data format","code":5,"invalid-event-number":0}', status: 400)

      d = create_driver
      d.emit({ "message" => "1" }, time)
      d.run

      assert_requested :post, "https://localhost:8089/services/collector/event",
        headers: {"Authorization" => "Splunk changeme"},
        body: { time: time, source: "test", sourcetype: "fluentd", host: "", index: "main", event: "1" },
        times: (case time when Integer then 1 when Float then 2 end)
    end
  end

  def test_5XX_error_retry
    [TIME_OBJ.to_i, TIME_OBJ.to_f].each do |time|
      request_count = 0
      stub_request(:post, "https://localhost:8089/services/collector/event").
        with(headers: {"Authorization" => "Splunk changeme"}).
        to_return do |request|
          request_count += 1

        if request_count < 5
          { body: '{"text":"Internal server error","code":8}', status: 500 }
        else
          { body: '{"text":"Success","code":0}', status: 200 }
        end
      end

      d = create_driver(CONFIG + %[
        post_retry_max 5
        post_retry_interval 0.1
      ])
      d.emit({ "message" => "1" }, time)
      d.run

      assert_requested :post, "https://localhost:8089/services/collector/event",
        headers: {"Authorization" => "Splunk changeme"},
        body: { time: time, source: "test", sourcetype: "fluentd", host: "", index: "main", event: "1" },
        times: (case time when Integer then 5 when Float then 10 end)
    end
  end

  def test_write_splitting
    [TIME_OBJ.to_i, TIME_OBJ.to_f].each do |time|
    stub_request(:post, "https://localhost:8089/services/collector/event").
      with(headers: {"Authorization" => "Splunk changeme"}).
      to_return(body: '{"text":"Incorrect data format","code":5,"invalid-event-number":0}', status: 400)

      # A single msg is ~110 bytes
      d = create_driver(CONFIG + %[
        batch_size_limit 250
      ])
      d.emit({"message" => "a" }, time)
      d.emit({"message" => "b" }, time)
      d.emit({"message" => "c" }, time)
      d.run

      assert_requested :post, "https://localhost:8089/services/collector/event",
        headers: {"Authorization" => "Splunk changeme"},
        body:
          { time: time, source: "test", sourcetype: "fluentd", host: "", index: "main", event: "a" }.to_json +
          { time: time, source: "test", sourcetype: "fluentd", host: "", index: "main", event: "b" }.to_json
      assert_requested :post, "https://localhost:8089/services/collector/event",
        headers: {"Authorization" => "Splunk changeme"},
        body: { time: time, source: "test", sourcetype: "fluentd", host: "", index: "main", event: "c" }.to_json
    end
    assert_requested :post, "https://localhost:8089/services/collector/event", times: 4
  end

  def test_utf8
    [TIME_OBJ.to_i, TIME_OBJ.to_f].each do |time|
      stub_request(:post, "https://localhost:8089/services/collector/event").
        with(headers: {"Authorization" => "Splunk changeme"}).
        to_return(body: '{"text":"Success","code":0}')

      d = create_driver(CONFIG + %[
        all_items true
      ])
      d.emit({ "some" => { "nested" => "ü†f-8".force_encoding("BINARY"), "with" => ['ü', '†', 'f-8'].map {|c| c.force_encoding("BINARY") } } }, time)
      d.run

      assert_requested :post, "https://localhost:8089/services/collector/event",
        headers: {"Authorization" => "Splunk changeme"},
        body: { time: time, source: "test", sourcetype: "fluentd", host: "", index: "main", event: { some: { nested: "     f-8", with: ["  ","   ","f-8"]}}},
        times: (case time when Integer then 1 when Float then 2 end)
    end
  end
end
