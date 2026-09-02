# frozen_string_literal: true

require 'spec_helper'
require 'belt/cli/environment_command'
require 'fileutils'
require 'tmpdir'

RSpec.describe Belt::CLI::EnvironmentCommand do
  around do |example|
    # Use a completely isolated tmpdir for each test to avoid pollution
    Dir.mktmpdir do |tmpdir|
      # Create minimal project structure for app detection
      FileUtils.mkdir_p(File.join(tmpdir, 'lambda'))
      File.write(File.join(tmpdir, 'lambda', 'api.rb'), '# gateway :api')

      Dir.chdir(tmpdir) do
        example.run
      end
    end
  end

  describe '.run' do
    it 'prints usage and exits when no env name provided' do
      expect { described_class.run([]) }.to raise_error(SystemExit)
    end

    it 'creates environment directory with standard files' do
      # Stub AWS call to avoid real API calls
      allow_any_instance_of(described_class).to receive(:bucket_from_aws).and_return('belt-state-123')

      expect { described_class.run(['dev']) }.to output(/Creating environment: dev/).to_stdout

      expect(Dir.exist?('infrastructure/dev')).to be true
      expect(File.exist?('infrastructure/dev/main.tf')).to be true
      expect(File.exist?('infrastructure/dev/terraform.tfvars')).to be true
      expect(File.exist?('infrastructure/dev/variables.tf')).to be true
      expect(File.exist?('infrastructure/dev/backend.tf')).to be true
      expect(File.exist?('infrastructure/dev/outputs.tf')).to be true
    end

    it 'rejects creation when environment already exists' do
      FileUtils.mkdir_p('infrastructure/dev')

      expect { described_class.run(['dev']) }.to raise_error(SystemExit)
    end

    context 'with parent environment' do
      before do
        # Create parent environment
        FileUtils.mkdir_p('infrastructure/dev')
        File.write('infrastructure/dev/terraform.tfvars', 'environment = "dev"')
        allow_any_instance_of(described_class).to receive(:bucket_from_aws).and_return('belt-state-123')
      end

      it 'accepts second argument as parent environment' do
        expect { described_class.run(%w[fizzy123 dev]) }.to output(/nested under dev/).to_stdout
      end

      it 'includes parent_environment in terraform.tfvars' do
        # Suppress stdout to avoid test output noise
        allow($stdout).to receive(:puts)
        described_class.run(%w[fizzy123 dev])

        tfvars = File.read('infrastructure/fizzy123/terraform.tfvars')
        expect(tfvars).to include('parent_environment = "dev"')
      end

      it 'rejects parent that does not exist' do
        expect { described_class.run(%w[fizzy123 nonexistent]) }.to raise_error(SystemExit)
      end

      it 'creates variables.tf with parent_environment variable' do
        allow($stdout).to receive(:puts)
        described_class.run(%w[fizzy123 dev])

        variables = File.read('infrastructure/fizzy123/variables.tf')
        expect(variables).to include('variable "parent_environment"')
      end

      it 'passes parent_environment to module in main.tf' do
        allow($stdout).to receive(:puts)
        described_class.run(%w[fizzy123 dev])

        main = File.read('infrastructure/fizzy123/main.tf')
        expect(main).to include('parent_environment  = var.parent_environment')
      end
    end

    context 'with parent environment that has domain and aws_profile' do
      before do
        FileUtils.mkdir_p('infrastructure/dev')
        File.write('infrastructure/dev/terraform.tfvars', <<~TFVARS)
          environment = "dev"
          domain      = "featureparity.dev"
        TFVARS
        File.write('infrastructure/dev/belt.rb', <<~RUBY)
          Belt.configure do |config|
            config.aws_profile = "fpdev"
          end
        RUBY
        allow_any_instance_of(described_class).to receive(:bucket_from_aws).and_return('belt-state-123')
      end

      it 'inherits domain from parent terraform.tfvars' do
        allow($stdout).to receive(:puts)
        described_class.run(%w[fizzy123 dev])

        tfvars = File.read('infrastructure/fizzy123/terraform.tfvars')
        expect(tfvars).to include('domain      = "featureparity.dev"')
      end

      it 'creates belt.rb with inherited aws_profile' do
        allow($stdout).to receive(:puts)
        described_class.run(%w[fizzy123 dev])

        expect(File.exist?('infrastructure/fizzy123/belt.rb')).to be true
        belt_rb = File.read('infrastructure/fizzy123/belt.rb')
        expect(belt_rb).to include('config.aws_profile = "fpdev"')
      end

      it 'shows correct domain in output message' do
        expect { described_class.run(%w[fizzy123 dev]) }
          .to output(/api\.fizzy123\.dev\.featureparity\.dev/).to_stdout
      end
    end

    context 'with parent environment that has no belt.rb' do
      before do
        FileUtils.mkdir_p('infrastructure/dev')
        File.write('infrastructure/dev/terraform.tfvars', 'environment = "dev"')
        allow_any_instance_of(described_class).to receive(:bucket_from_aws).and_return('belt-state-123')
      end

      it 'does not create belt.rb when parent has no aws_profile' do
        allow($stdout).to receive(:puts)
        described_class.run(%w[fizzy123 dev])

        expect(File.exist?('infrastructure/fizzy123/belt.rb')).to be false
      end
    end
  end

  describe 'standalone environment (no parent)' do
    before do
      allow_any_instance_of(described_class).to receive(:bucket_from_aws).and_return('belt-state-123')
    end

    it 'does not include parent_environment in terraform.tfvars' do
      allow($stdout).to receive(:puts)
      described_class.run(['staging'])

      tfvars = File.read('infrastructure/staging/terraform.tfvars')
      expect(tfvars).not_to include('parent_environment')
    end
  end
end
