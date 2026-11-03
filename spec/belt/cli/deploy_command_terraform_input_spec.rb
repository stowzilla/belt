# frozen_string_literal: true

require 'spec_helper'
require 'belt/cli/deploy_command'

# Regression coverage for the deploy hang: `belt deploy` ran `terraform plan`
# (and init/apply) without `-input=false` and left popen3's stdin open, so any
# interactive terraform prompt blocked the deploy forever with nobody at the
# keyboard. These examples pin the non-interactive flags and the stdin close so
# the hang can't silently come back.
RSpec.describe Belt::CLI::DeployCommand, 'non-interactive terraform invocations' do
  subject(:cmd) { described_class.new('superman', auto_approve: true, extra_args: []) }

  before do
    # Don't touch the real filesystem/project during construction-dependent calls.
    allow(Belt::CLI::TerraformCommand).to receive(:find_infrastructure_dir).and_return('infrastructure')
    allow(cmd).to receive(:find_project_root).and_return('.') if cmd.respond_to?(:find_project_root, true)
  end

  describe '#run_init' do
    it 'passes -input=false so init never blocks on a prompt' do
      captured = nil
      allow(cmd).to receive(:system) do |*args|
        captured = args
        true
      end

      cmd.send(:run_init)

      expect(captured).to eq(['terraform', 'init', '-input=false'])
    end
  end

  describe '#run_terraform_plan' do
    it 'passes -input=false, sets TF_IN_AUTOMATION, and closes stdin' do
      captured_env = nil
      captured_cmd = nil
      stdin = instance_double(IO)
      stdout = StringIO.new('')
      stderr = StringIO.new('')
      wait_thr = instance_double(Process::Waiter, value: instance_double(Process::Status, success?: true))

      expect(stdin).to receive(:close)

      allow(Open3).to receive(:popen3) do |env, *tf_cmd, &block|
        captured_env = env
        captured_cmd = tf_cmd
        block.call(stdin, stdout, stderr, wait_thr)
      end

      cmd.send(:run_terraform_plan)

      expect(captured_env).to eq('TF_IN_AUTOMATION' => '1')
      expect(captured_cmd).to eq(['terraform', 'plan', '-input=false', '-out=tfplan'])
    end
  end

  describe '#run_apply' do
    it 'passes -input=false when applying the saved plan' do
      captured = nil
      allow(cmd).to receive(:system) do |*args|
        captured = args
        true
      end
      allow(cmd).to receive(:cleanup_plan)

      cmd.send(:run_apply)

      expect(captured).to eq(['terraform', 'apply', '-input=false', 'tfplan'])
    end
  end
end
