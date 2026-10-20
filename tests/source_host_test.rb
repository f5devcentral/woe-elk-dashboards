# Unit tests for the source_host normalisation in charts/elk/files/logstash-waf.conf.
#
# The Ruby between the "BEGIN source_host" / "END source_host" markers is
# extracted from the shipped pipeline and run against a minimal stand-in for a
# Logstash event, so these tests always exercise the deployed code.
#
#   ruby tests/source_host_test.rb
require "minitest/autorun"
require "ipaddr"

PIPELINE = File.expand_path("../charts/elk/files/logstash-waf.conf", __dir__)
SNIPPET = File.read(PIPELINE)[/# BEGIN source_host\n(.*?)\n\s*# END source_host/m, 1] or
  abort "source_host markers not found in #{PIPELINE}"

class FakeEvent
  def initialize(fields)
    @fields = fields.dup
  end

  def get(key)
    @fields[key]
  end

  def set(key, value)
    @fields[key] = value
  end

  def remove(key)
    @fields.delete(key)
  end
end

class SourceHostTest < Minitest::Test
  def source_host(xff, ip_client = "10.0.0.9")
    fields = { "x_forwarded_for_header_value" => xff, "ip_client" => ip_client }
    fields.delete("x_forwarded_for_header_value") if xff.nil?
    event = FakeEvent.new(fields)
    eval(SNIPPET, binding) # rubocop:disable Security/Eval -- the snippet under test
    event.get("source_host")
  end

  def test_single_address
    assert_equal "51.15.0.1", source_host("51.15.0.1")
  end

  def test_proxy_chain_uses_left_most_client
    assert_equal "51.15.0.1", source_host("51.15.0.1,84.108.132.213")
    assert_equal "51.15.0.1", source_host("51.15.0.1, 84.108.132.213, 10.1.2.3")
  end

  def test_whitespace_and_quotes
    assert_equal "51.15.0.1", source_host("  51.15.0.1 ,84.108.132.213 ")
    assert_equal "51.15.0.1", source_host("\"51.15.0.1\"")
  end

  def test_skips_invalid_leading_entries
    assert_equal "84.108.132.213", source_host("unknown, 84.108.132.213")
    assert_equal "84.108.132.213", source_host(", 84.108.132.213")
  end

  def test_ipv6
    assert_equal "2001:db8::1", source_host("2001:db8::1, 51.15.0.1")
    assert_equal "2001:db8::1", source_host("[2001:db8::1]:443")
    assert_equal "2001:db8::1", source_host("2001:0db8:0000:0000:0000:0000:0000:0001")
  end

  def test_ipv4_with_port
    assert_equal "51.15.0.1", source_host("51.15.0.1:5678, 84.108.132.213")
  end

  def test_rejects_cidr_and_zone_ids
    assert_equal "10.0.0.9", source_host("51.15.0.0/24")
    assert_equal "10.0.0.9", source_host("fe80::1%eth0")
  end

  def test_falls_back_to_ip_client
    assert_equal "10.0.0.9", source_host("N/A")
    assert_equal "10.0.0.9", source_host(" N/A ")
    assert_equal "10.0.0.9", source_host(nil)
    assert_equal "10.0.0.9", source_host("")
    assert_equal "10.0.0.9", source_host("unknown, garbage")
  end

  def test_unset_when_nothing_valid
    assert_nil source_host("N/A", "N/A")
    assert_nil source_host("bogus", nil)
  end
end
