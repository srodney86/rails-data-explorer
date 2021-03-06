# -*- coding: utf-8 -*-

# Responsibilities:
#  * Integrate all the pieces required for this gem
#  * Initialize a collection of Explorations
#
# Collaborators:
#  * Exploration
class RailsDataExplorer

  GREATER_ZERO = 1.0 / 1_000_000 # The smallest value to use if we have to avoid zero (div by zero)

  attr_reader :explorations
  attr_reader :data_series_names

  # Top level initialization. This is what you use to explore your data.
  # @param data_collection [Array<Array>] Outer array is the container, inner
  #                                       array represents each record (row of data).
  # @param data_series_specs [Array<Hash>] One Hash for each data series.
  # @option data_series_specs [String] :name the name of the data series
  # @option data_series_specs [Proc] :data_method a proc that will return the
  #                                   data for this column. Valid types are
  #                                   String, Numeric or Date/Time.
  # @option data_series_specs [String] :note any comment you want to make for
  #                                   this data series. Will be printed with
  #                                   each chart that uses this data series.
  # @option data_series_specs [Boolean, String] :univariate override to always
  #                                   render univariate chart and statistics for
  #                                   this data series. Defaults to true.
  # @option data_series_specs [Boolean, String] :bivariate override to always
  #                                   render bivariate chart and statistics for
  #                                   this data series. Defaults to false.
  # @option data_series_specs [Boolean, String] :multivariate override to always
  #                                   render multivariate chart and statistics for
  #                                   this data series. Defaults to false.
  # @option data_series_specs [Integer] :max_num_distinct_values override the
  #                                   max number of distinct values for
  #                                   categorical data. Default: 20.
  # @param explorations_to_render [Hash] A hash to specify which explorations
  #     you want rendered. Example data structure:
  #        {
  #          "univariate" => {
  #            "1" => ["Hour of day"],
  #          },
  #          "bivariate" => {
  #            "1" => ["Context", "Release (major)"],
  #            "2" => ["Year", "Timezone"],
  #          }
  #        }
  #
  def initialize(data_collection, data_series_specs, explorations_to_render)
    @explorations = []
    charts = {
      univariate: [],
      bivariate: {},
      multivariate: {}
    }
    @data_series_names = data_series_specs.map { |e| e[:name] }

    @cached_data_series = data_series_specs.inject({}) { |m, ds_spec|
      m[ds_spec[:name]] = DataSeries.new(
        ds_spec[:name],
        data_collection.map(&ds_spec[:data_method]),
        ds_spec
      )
      m
    }

    # Default to all univariate explorations
    explorations_to_render = (
      explorations_to_render || @data_series_names.inject({ univariate: {}}) { |m,e|
        m[:univariate][e] = [e]
        m
      }
    ).symbolize_keys

    # Build list of all available explorations (rendered and not rendered),
    # grouped by type_of_analysis
    data_series_specs.each do |data_series_spec|

      charts[:univariate] << data_series_spec.dup

      charts[:bivariate]['rde-default'] ||= []
      charts[:bivariate]['rde-default'] << data_series_spec.dup

      # No defaults for multivariate yet... Have to be specified manually via
      # data_series specs
      if data_series_spec[:multivariate]
        [*data_series_spec[:multivariate]].each { |group_key|
          group_key = group_key.to_s
          charts[:multivariate][group_key] ||= []
          charts[:multivariate][group_key] << data_series_spec.dup
        }
      end

    end

    charts[:univariate].uniq.compact.each { |data_series_spec|
      @explorations << Exploration.new(
        data_series_spec[:name],
        DataSet.new(
          [@cached_data_series[data_series_spec[:name]]],
          data_series_spec[:name]
        ),
        render_exploration_for?(
          explorations_to_render,
          :univariate,
          [data_series_spec[:name]]
        )
      )
    }

    charts[:bivariate].each { |group_key, bv_data_series_specs|
      next  unless group_key # skip if key is falsey
      bv_data_series_specs.uniq.compact.combination(2) { |ds_specs_pair|
        @explorations << build_exploration_from_data_series_specs(
          data_collection,
          ds_specs_pair,
          render_exploration_for?(
            explorations_to_render,
            :bivariate,
            ds_specs_pair.map { |e| e[:name] }
          )
        )
      }
    }

    charts[:multivariate].each { |group_key, mv_data_series_specs|
      next  unless group_key # skip key `false` or `nil`
      ds_specs = mv_data_series_specs.uniq.compact
      @explorations << build_exploration_from_data_series_specs(
        data_collection,
        ds_specs,
        true # always render multivariate since they are specified manually
      )
    }
  end

  # @return [Array<Exploration>]
  def explorations_with_charts_available
    explorations.find_all { |e| e.charts.any? }
  end

  # @return [Array<Exploration>]
  def explorations_with_charts_to_render
    explorations_with_charts_available.find_all { |e| e.render_charts? }
  end

  # @return [Array<Exploration>]
  def explorations_with_no_charts_available
    explorations.find_all { |e| e.charts.empty? }
  end

  # @return [Integer]
  def number_of_values
    explorations.first.number_of_values
  end

private

  def build_exploration_from_data_series_specs(data_collection, ds_specs, render_charts)
    expl_title = ds_specs.map { |e| e[:name] }.sort.join(' vs. ')
    Exploration.new(
      expl_title,
      DataSet.new(
        ds_specs.map { |ds_spec| @cached_data_series[ds_spec[:name]] },
        expl_title
      ),
      render_charts
    )
  end

  # Returns true if data_series with data_series_names should have charts for
  # explorations with type_of_analysis rendered.
  # @param explorations_to_render [Hash]
  #     {:bivariate=>{"rde-exploration-context-year"=>["Context", "Year"]}}
  # @param type_of_analysis [Symbol] one of :univariate, :bivariate, :multivariate
  # @param data_series_names [Array<String>] names of data_series to return answer for
  # @return [Boolean]
  def render_exploration_for?(explorations_to_render, type_of_analysis, data_series_names)
    case type_of_analysis
    when :univariate
      # Return true if a :univariate exploration exists that contains data_series_names
      (explorations_to_render[:univariate] || []).any? { |dom_id, ds_names|
        data_series_names.sort == ds_names.sort
      }
    when :bivariate
      # Return true if a :bivariate exploration exists that contains data_series_names
      (explorations_to_render[:bivariate] || []).any? { |dom_id, ds_names|
        data_series_names.sort == ds_names.sort
      }
    else
      raise "Handle this type_of_analysis: #{ type_of_analysis.inspect }"
    end
  end

end
