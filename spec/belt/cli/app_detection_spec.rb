# frozen_string_literal: true

require 'spec_helper'
require 'belt/cli/app_detection'

RSpec.describe Belt::CLI::AppDetection do
  let(:test_class) { Class.new { include Belt::CLI::AppDetection }.new }

  around do |example|
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) { example.run }
    end
  end

  describe '#detect_app_name' do
    context 'when terraform.tfvars has app_name' do
      before do
        FileUtils.mkdir_p('infrastructure/prod')
        File.write('infrastructure/prod/terraform.tfvars', 'app_name = "stowzilla"')
      end

      it 'returns the tfvars app_name' do
        expect(test_class.detect_app_name).to eq('stowzilla')
      end
    end

    context 'when variables.tf has app_name with default' do
      before do
        FileUtils.mkdir_p('infrastructure/dev04')
        File.write('infrastructure/dev04/variables.tf', <<~TF)
          variable "app_name" {
            description = "Name of the application"
            type        = string
            default     = "stowzilla"
          }
        TF
      end

      it 'returns the variables.tf default value' do
        expect(test_class.detect_app_name).to eq('stowzilla')
      end
    end

    context 'when tfvars and variables.tf both exist' do
      before do
        FileUtils.mkdir_p('infrastructure/prod')
        File.write('infrastructure/prod/terraform.tfvars', 'app_name = "from-tfvars"')
        File.write('infrastructure/prod/variables.tf', <<~TF)
          variable "app_name" {
            default = "from-variables"
          }
        TF
      end

      it 'prefers tfvars over variables.tf' do
        expect(test_class.detect_app_name).to eq('from-tfvars')
      end
    end

    context 'when neither tfvars nor variables.tf has app_name' do
      it 'falls back to directory name' do
        expect(test_class.detect_app_name).to eq(File.basename(Dir.pwd))
      end
    end

    context 'when variables.tf has app_name without a default' do
      before do
        FileUtils.mkdir_p('infrastructure/prod')
        File.write('infrastructure/prod/variables.tf', <<~TF)
          variable "app_name" {
            description = "Name of the application"
            type        = string
          }
        TF
      end

      it 'falls back to directory name' do
        expect(test_class.detect_app_name).to eq(File.basename(Dir.pwd))
      end
    end
  end
end
