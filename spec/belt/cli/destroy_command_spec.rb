# frozen_string_literal: true

require 'spec_helper'
require 'belt/cli/destroy_command'
require 'fileutils'
require 'tmpdir'
require 'stringio'

RSpec.describe Belt::CLI::DestroyCommand do
  # Every example runs in an isolated tmpdir with a minimal project + environment,
  # so we never touch the real project tree or the developer's AWS profile permanently.
  around do |example|
    original_profile = ENV.fetch('AWS_PROFILE', nil)
    Dir.mktmpdir do |tmpdir|
      # Minimal app structure so AppDetection#detect_namespace doesn't blow up.
      FileUtils.mkdir_p(File.join(tmpdir, 'lambda'))
      File.write(File.join(tmpdir, 'lambda', 'api.rb'), '# gateway :api')

      Dir.chdir(tmpdir) { example.run }
    end
  ensure
    # Restore the shell's AWS_PROFILE — apply! mutates ENV in-process.
    if original_profile.nil?
      ENV.delete('AWS_PROFILE')
    else
      ENV['AWS_PROFILE'] = original_profile
    end
  end

  # Build an environment dir with an optional belt.rb config.
  def make_env(name, belt_rb: nil, tfvars: 'environment = "superman"')
    dir = "infrastructure/#{name}"
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'terraform.tfvars'), tfvars)
    File.write(File.join(dir, 'belt.rb'), belt_rb) if belt_rb
    dir
  end

  # Feed prompt responses to the command via $stdin.
  def answer(*responses)
    io = StringIO.new("#{responses.join("\n")}\n")
    allow($stdin).to receive(:gets) { io.gets }
  end

  describe 'belt destroy environment — AWS profile handling' do
    let(:belt_rb) do
      <<~RUBY
        Belt.configure do |config|
          config.aws_profile = 'fpdev'
        end
      RUBY
    end

    context 'when terraform state exists and the user confirms destroy' do
      it "applies the environment's aws_profile from belt.rb before running terraform" do
        make_env('superman', belt_rb: belt_rb)
        ENV['AWS_PROFILE'] = 'devzilla' # simulate the wrong shell profile

        cmd = described_class.new('environment', 'superman', [], force: false, skip_terraform: false)

        # Capture the profile that was live at the moment terraform destroy ran.
        profile_during_destroy = nil
        allow(cmd).to receive(:terraform_state_exists?).and_return(true)
        allow(cmd).to receive(:run_terraform_destroy) { profile_during_destroy = ENV.fetch('AWS_PROFILE', nil) }
        allow(cmd).to receive(:warn_about_dns_delegation)

        answer('y', 'y') # confirm terraform destroy, then confirm file deletion

        expect { cmd.destroy }.to output(/Using AWS profile: fpdev/).to_stdout
        expect(profile_during_destroy).to eq('fpdev')
      end

      it 'applies the profile BEFORE terraform state detection, not after' do
        make_env('superman', belt_rb: belt_rb)
        ENV['AWS_PROFILE'] = 'devzilla'

        cmd = described_class.new('environment', 'superman', [], skip_terraform: false)

        profile_during_state_check = nil
        allow(cmd).to receive(:terraform_state_exists?) do
          profile_during_state_check = ENV.fetch('AWS_PROFILE', nil)
          false # no state → skip the destroy prompt entirely
        end
        allow(cmd).to receive(:warn_about_dns_delegation)

        answer('y') # confirm file deletion

        allow($stdout).to receive(:puts)
        allow($stdout).to receive(:print)
        cmd.destroy

        # The fix must pin the correct profile before we even probe remote state,
        # because terraform_state_exists? itself shells out to `terraform show`.
        expect(profile_during_state_check).to eq('fpdev')
      end
    end

    context 'when --skip-terraform is passed' do
      it 'does NOT apply the env config (no terraform/aws calls happen)' do
        make_env('superman', belt_rb: belt_rb)
        ENV['AWS_PROFILE'] = 'devzilla'

        cmd = described_class.new('environment', 'superman', [], force: false, skip_terraform: true)
        allow(cmd).to receive(:warn_about_dns_delegation)

        # apply_env_config! must not fire when we're only deleting local files.
        expect(cmd).not_to receive(:apply_env_config!)

        answer('y') # confirm file deletion
        allow($stdout).to receive(:puts)
        allow($stdout).to receive(:print)
        cmd.destroy

        # Shell profile untouched by the command.
        expect(ENV.fetch('AWS_PROFILE', nil)).to eq('devzilla')
      end
    end

    context 'when --force is passed with terraform state present' do
      it 'still applies the env profile even though it skips the destroy prompt' do
        make_env('superman', belt_rb: belt_rb)
        ENV['AWS_PROFILE'] = 'devzilla'

        cmd = described_class.new('environment', 'superman', [], force: true, skip_terraform: false)
        allow(cmd).to receive(:terraform_state_exists?).and_return(true)
        allow(cmd).to receive(:warn_about_dns_delegation)

        expect { cmd.destroy }.to output(/Using AWS profile: fpdev/).to_stdout
      end
    end

    context 'when the environment has no belt.rb' do
      it 'runs cleanly without a profile line and leaves AWS_PROFILE untouched' do
        make_env('superman', belt_rb: nil)
        ENV['AWS_PROFILE'] = 'devzilla'

        cmd = described_class.new('environment', 'superman', [], skip_terraform: false)
        allow(cmd).to receive(:terraform_state_exists?).and_return(false)
        allow(cmd).to receive(:warn_about_dns_delegation)

        answer('y')

        # EnvironmentConfig.load returns an unconfigured config → no aws_profile line.
        expect { cmd.destroy }.not_to output(/Using AWS profile/).to_stdout
        expect(ENV.fetch('AWS_PROFILE', nil)).to eq('devzilla')
      end
    end
  end

  describe '#apply_env_config!' do
    it 'sets AWS_PROFILE from the environment belt.rb' do
      make_env('superman', belt_rb: <<~RUBY)
        Belt.configure do |config|
          config.aws_profile = 'fpdev'
        end
      RUBY

      ENV['AWS_PROFILE'] = 'devzilla'
      cmd = described_class.new('environment', 'superman', [])

      expect { cmd.send(:apply_env_config!) }.to output(/Using AWS profile: fpdev/).to_stdout
      expect(ENV.fetch('AWS_PROFILE', nil)).to eq('fpdev')
    end

    it 'applies env vars declared in belt.rb' do
      make_env('superman', belt_rb: <<~RUBY)
        Belt.configure do |config|
          config.env do
            set :FOO_BAR, 'baz'
          end
        end
      RUBY

      cmd = described_class.new('environment', 'superman', [])
      allow($stdout).to receive(:puts)
      cmd.send(:apply_env_config!)

      expect(ENV.fetch('FOO_BAR', nil)).to eq('baz')
    ensure
      ENV.delete('FOO_BAR')
    end

    it 'does not print a profile line when belt.rb sets no aws_profile' do
      make_env('superman', belt_rb: <<~RUBY)
        Belt.configure do |config|
          config.env do
            set :SOMETHING, 'x'
          end
        end
      RUBY

      cmd = described_class.new('environment', 'superman', [])

      expect { cmd.send(:apply_env_config!) }.not_to output(/Using AWS profile/).to_stdout
    ensure
      ENV.delete('SOMETHING')
    end
  end
end
