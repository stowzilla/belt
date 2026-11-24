# frozen_string_literal: true

require 'json'
require 'open3'

module Belt
  module CLI
    # Finds the DNS validation records for ACM certificates that are still
    # PENDING_VALIDATION for a domain, by asking ACM directly.
    #
    # Terraform outputs and state can't be used here: during a first apply the
    # cert exists in ACM long before Terraform writes it anywhere we can read,
    # and aws_acm_certificate_validation blocks the apply until the CNAME is
    # published. Reading ACM lets `belt deploy` publish the CNAME mid-apply.
    module AcmPendingValidation
      # Belt's module uses one cert for CloudFront and API Gateway. CloudFront
      # only accepts certs from us-east-1, so that's where it always lives.
      REGION = 'us-east-1'

      module_function

      # Returns [{ name:, type:, value: }] for every pending DNS validation
      # record of certs whose primary name is +domain+, deduped by name (the
      # apex and its wildcard share one CNAME). Returns [] on any AWS error.
      def records(domain, aws_env = {})
        return [] if domain.nil? || domain.empty?

        pending_cert_arns(domain, aws_env)
          .flat_map { |arn| validation_records(arn, aws_env) }
          .uniq { |r| r[:name] }
      end

      def pending_cert_arns(domain, aws_env)
        output, status = Open3.capture2e(
          aws_env,
          'aws', 'acm', 'list-certificates',
          '--region', REGION,
          '--certificate-statuses', 'PENDING_VALIDATION',
          '--output', 'json'
        )
        return [] unless status.success?

        summaries = parse_json(output)&.fetch('CertificateSummaryList', nil) || []
        summaries.select { |c| c['DomainName'] == domain }.map { |c| c['CertificateArn'] }
      end

      def validation_records(cert_arn, aws_env)
        output, status = Open3.capture2e(
          aws_env,
          'aws', 'acm', 'describe-certificate',
          '--region', REGION,
          '--certificate-arn', cert_arn,
          '--output', 'json'
        )
        return [] unless status.success?

        options = parse_json(output)&.dig('Certificate', 'DomainValidationOptions') || []
        options.filter_map do |opt|
          next unless opt['ValidationMethod'] == 'DNS'
          next if opt['ValidationStatus'] == 'SUCCESS'

          # ACM fills ResourceRecord in a few seconds after the cert is created.
          rr = opt['ResourceRecord']
          next unless rr

          { name: rr['Name'], type: rr['Type'], value: rr['Value'] }
        end
      end

      def parse_json(output)
        JSON.parse(output)
      rescue JSON::ParserError
        nil
      end
    end
  end
end
