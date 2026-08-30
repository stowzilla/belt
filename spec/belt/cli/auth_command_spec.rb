# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'belt/cli/auth_command'

RSpec.describe Belt::CLI::AuthCommand do
  let(:tmpdir) { Dir.mktmpdir }
  let(:module_dir) { File.join(tmpdir, 'infrastructure/modules/app') }
  let(:original_dir) { Dir.pwd }

  before do
    @original_dir = Dir.pwd
    FileUtils.mkdir_p(module_dir)
    # Create a minimal main.tf with conveyor_belt resource
    File.write(File.join(module_dir, 'main.tf'), <<~HCL)
      resource "conveyor_belt" "main" {
        provider = conveyor-belt
        source   = "config/routes.rb"
        app_name = var.app_name
      }
    HCL

    # Create minimal tfvars for app name detection
    env_dir = File.join(tmpdir, 'infrastructure/dev')
    FileUtils.mkdir_p(env_dir)
    File.write(File.join(env_dir, 'terraform.tfvars'), 'app_name = "myapp"')

    Dir.chdir(tmpdir)
  end

  after do
    Dir.chdir(@original_dir)
    FileUtils.rm_rf(tmpdir)
  end

  describe '.run with single pool (default)' do
    it 'creates cognito.tf and cognito_outputs.tf' do
      expect { described_class.run([]) }.to output(/create.*cognito\.tf/).to_stdout

      cognito_tf = File.join(module_dir, 'cognito.tf')
      outputs_tf = File.join(module_dir, 'cognito_outputs.tf')

      expect(File.exist?(cognito_tf)).to be true
      expect(File.exist?(outputs_tf)).to be true

      content = File.read(cognito_tf)
      expect(content).to include('aws_cognito_user_pool" "main"')
      expect(content).to include('aws_cognito_user_pool_client" "main"')
      expect(content).to include('${var.app_name}-${var.environment}')
      expect(content).not_to include('-main')

      outputs = File.read(outputs_tf)
      expect(outputs).to include('cognito_user_pool_id')
      expect(outputs).to include('cognito_client_id')
    end

    it 'patches main.tf with cognito_user_pool_arns' do
      expect { described_class.run([]) }.to output(/update.*main\.tf/).to_stdout

      content = File.read(File.join(module_dir, 'main.tf'))
      expect(content).to include('cognito_user_pool_arns = [aws_cognito_user_pool.main.arn]')
    end
  end

  describe '.run with multiple pools' do
    it 'creates resources for each pool' do
      expect { described_class.run(%w[web mobile]) }.to output(/create.*cognito\.tf/).to_stdout

      content = File.read(File.join(module_dir, 'cognito.tf'))
      expect(content).to include('aws_cognito_user_pool" "web"')
      expect(content).to include('aws_cognito_user_pool" "mobile"')
      expect(content).to include('-web')
      expect(content).to include('-mobile')

      outputs = File.read(File.join(module_dir, 'cognito_outputs.tf'))
      expect(outputs).to include('cognito_user_pool_id-web')
      expect(outputs).to include('cognito_user_pool_id-mobile')
      expect(outputs).to include('cognito_client_id-web')
      expect(outputs).to include('cognito_client_id-mobile')
    end

    it 'patches main.tf with multiple ARNs' do
      expect { described_class.run(%w[web mobile]) }.to output(/update.*main\.tf/).to_stdout

      content = File.read(File.join(module_dir, 'main.tf'))
      expect(content).to include('aws_cognito_user_pool.web.arn')
      expect(content).to include('aws_cognito_user_pool.mobile.arn')
    end
  end

  describe 'collision detection' do
    it 'exits if cognito.tf already exists' do
      File.write(File.join(module_dir, 'cognito.tf'), 'existing')

      expect { described_class.run([]) }.to raise_error(SystemExit)
        .and output(/already exists/).to_stdout
    end

    it 'allows --force to overwrite' do
      File.write(File.join(module_dir, 'cognito.tf'), 'existing')

      expect { described_class.run(['--force']) }.to output(/create.*cognito\.tf/).to_stdout
      expect(File.read(File.join(module_dir, 'cognito.tf'))).to include('aws_cognito_user_pool')
    end
  end

  describe '.destroy' do
    before do
      # Generate first
      capture_output { described_class.run([]) }
    end

    it 'removes cognito.tf and cognito_outputs.tf' do
      expect { described_class.destroy([]) }.to output(/remove.*cognito\.tf/).to_stdout

      expect(File.exist?(File.join(module_dir, 'cognito.tf'))).to be false
      expect(File.exist?(File.join(module_dir, 'cognito_outputs.tf'))).to be false
    end

    it 'removes cognito_user_pool_arns from main.tf' do
      expect { described_class.destroy([]) }.to output(/removed cognito_user_pool_arns/).to_stdout

      content = File.read(File.join(module_dir, 'main.tf'))
      expect(content).not_to include('cognito_user_pool_arns')
    end
  end

  describe 'skip patch when cognito_user_pool_arns already present' do
    it 'does not duplicate the attribute' do
      main_tf = File.join(module_dir, 'main.tf')
      content = File.read(main_tf)
      content.sub!(/\}\s*\z/, "  cognito_user_pool_arns = [aws_cognito_user_pool.existing.arn]\n}")
      File.write(main_tf, content)

      expect { described_class.run(['--force']) }.to output(/skip.*main\.tf/).to_stdout
    end
  end

  describe '.run with --ses-email' do
    it 'creates cognito_variables.tf with SES variables' do
      expect { described_class.run(['--ses-email']) }.to output(/create.*cognito_variables\.tf/).to_stdout

      variables_tf = File.join(module_dir, 'cognito_variables.tf')
      expect(File.exist?(variables_tf)).to be true

      content = File.read(variables_tf)
      expect(content).to include('variable "cognito_ses_email_arn"')
      expect(content).to include('variable "cognito_from_email"')
      expect(content).to include('variable "cognito_reply_to_email"')
    end

    it 'adds email_configuration block to cognito.tf' do
      capture_output { described_class.run(['--ses-email']) }

      content = File.read(File.join(module_dir, 'cognito.tf'))
      expect(content).to include('email_configuration')
      expect(content).to include('email_sending_account  = "DEVELOPER"')
      expect(content).to include('source_arn             = var.cognito_ses_email_arn')
      expect(content).to include('from_email_address     = var.cognito_from_email')
    end

    it 'patches environment tfvars with commented SES variables when no domain' do
      expect { described_class.run(['--ses-email']) }.to output(/update.*terraform\.tfvars.*SES/).to_stdout

      tfvars = File.read(File.join(tmpdir, 'infrastructure/dev/terraform.tfvars'))
      expect(tfvars).to include('# cognito_ses_email_arn')
      expect(tfvars).to include('# cognito_from_email')
      expect(tfvars).to include('yourdomain.com')
    end

    context 'when domain is configured in tfvars' do
      before do
        tfvars_path = File.join(tmpdir, 'infrastructure/dev/terraform.tfvars')
        File.write(tfvars_path, %(app_name = "myapp"\ndomain   = "coolapp.io"\n))
      end

      it 'generates uncommented SES variables with domain-based defaults' do
        expect { described_class.run(['--ses-email']) }.to output(/update.*terraform\.tfvars.*SES/).to_stdout

        tfvars = File.read(File.join(tmpdir, 'infrastructure/dev/terraform.tfvars'))
        expect(tfvars).to include('cognito_ses_email_arn  = "arn:aws:ses:REGION:ACCOUNT:identity/coolapp.io"')
        expect(tfvars).to include('cognito_from_email     = "noreply@coolapp.io"')
        expect(tfvars).to include('# cognito_reply_to_email = "support@coolapp.io"')
      end
    end
  end

  describe '.destroy with SES email' do
    before do
      # Generate with SES email first
      capture_output { described_class.run(['--ses-email']) }
    end

    it 'removes cognito_variables.tf' do
      expect { described_class.destroy([]) }.to output(/remove.*cognito_variables\.tf/).to_stdout

      expect(File.exist?(File.join(module_dir, 'cognito_variables.tf'))).to be false
    end
  end

  private

  def capture_output(&block)
    original_stdout = $stdout
    $stdout = StringIO.new
    block.call
  ensure
    $stdout = original_stdout
  end
end
