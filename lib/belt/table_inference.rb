# frozen_string_literal: true

module Belt
  # Infers DynamoDB table names from route paths by matching against
  # tables defined in a Terraform file containing aws_dynamodb_table resources.
  class TableInference
    attr_reader :available_tables

    def initialize(dynamodb_tables_file)
      @available_tables = if dynamodb_tables_file && File.exist?(dynamodb_tables_file)
                            parse_available_tables(dynamodb_tables_file)
                          else
                            []
                          end
    end

    def infer_tables_from_route(route)
      path_segments = route.path.split('/').reject(&:empty?)
      return [] if path_segments.empty?

      resource_segment = path_segments.find { |seg| !seg.start_with?('{') }
      return [] unless resource_segment

      inferred = find_matching_table(resource_segment)
      inferred ? [inferred] : []
    end

    private

    def parse_available_tables(file_path)
      content = File.read(file_path)
      content.scan(/resource\s+"aws_dynamodb_table"\s+"(\w+)"\s*\{/).flatten
    end

    def find_matching_table(resource_name)
      return resource_name if @available_tables.include?(resource_name)

      plural = pluralize(resource_name)
      return plural if @available_tables.include?(plural)

      singular = singularize(resource_name)
      return singular if @available_tables.include?(singular)

      nil
    end

    def pluralize(word)
      if word.end_with?('y')
        "#{word[0..-2]}ies"
      elsif word.end_with?('s', 'x', 'z', 'ch', 'sh')
        "#{word}es"
      else
        "#{word}s"
      end
    end

    def singularize(word)
      if word.end_with?('ies')
        "#{word[0..-4]}y"
      elsif word.end_with?('xes', 'zes', 'ses')
        word[0..-3]
      elsif word.end_with?('ches', 'shes')
        word[0..-3]
      elsif word.end_with?('s') && !word.end_with?('ss')
        word[0..-2]
      else
        word
      end
    end
  end
end
