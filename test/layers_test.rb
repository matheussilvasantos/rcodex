# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"

class LayersTest < Minitest::Test
  LIB = File.expand_path("../lib", __dir__)

  def test_domain_loads_without_application_or_infrastructure
    assert_layer_loads("rcodex/domain/rate_limits", %w[application infrastructure])
  end

  def test_application_loads_without_infrastructure
    assert_layer_loads("rcodex/application/cli", %w[infrastructure])
  end

  private

  def assert_layer_loads(feature, forbidden_layers)
    script = <<~RUBY
      require #{feature.inspect}
      forbidden = #{forbidden_layers.inspect}
      dependencies = $LOADED_FEATURES.select do |path|
        forbidden.any? { |layer| path.include?("/rcodex/\#{layer}/") }
      end
      abort dependencies.join("\n") unless dependencies.empty?
    RUBY
    output, error, status = Open3.capture3(RbConfig.ruby, "-I", LIB, "-e", script)
    assert status.success?, error
    assert_empty output
    assert_empty error
  end
end
