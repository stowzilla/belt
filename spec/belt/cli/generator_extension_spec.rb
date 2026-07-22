# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'belt/cli/generate_command'
require 'belt/cli/destroy_command'

RSpec.describe 'Generator extension integration' do
  let(:gem_dir) { Dir.mktmpdir }
  let(:generators_dir) { File.join(gem_dir, 'lib/belt/generators') }
  let(:run_args) { [] }
  let(:destroy_args) { [] }

  before do
    Belt::CLI::GeneratorRegistry.reset!
    FileUtils.mkdir_p(generators_dir)

    File.write(File.join(generators_dir, 'messaging_generator.rb'), <<~RUBY)
      module Belt
        module Generators
          class MessagingGenerator
            def self.run(args)
              @last_run_args = args
            end

            def self.destroy(args)
              @last_destroy_args = args
            end

            def self.description
              "Install two-way SMS messaging"
            end

            def self.last_run_args
              @last_run_args
            end

            def self.last_destroy_args
              @last_destroy_args
            end
          end
        end
      end
    RUBY

    fake_spec = instance_double(Gem::Specification, gem_dir: gem_dir)
    allow(Gem).to receive(:loaded_specs).and_return({ 'belt-messaging' => fake_spec })
  end

  after do
    Belt::CLI::GeneratorRegistry.reset!
    FileUtils.rm_rf(gem_dir)
    # Clean up the const if it was loaded
    if Belt::Generators.const_defined?(:MessagingGenerator)
      Belt::Generators.send(:remove_const, :MessagingGenerator)
    end
  end

  describe 'GenerateCommand' do
    it 'delegates to the gem generator when name matches' do
      Belt::CLI::GenerateCommand.run(['messaging', '--verbose'])
      expect(Belt::Generators::MessagingGenerator.last_run_args).to eq(['--verbose'])
    end

    it 'still rejects truly unknown generators' do
      expect { Belt::CLI::GenerateCommand.run(['unicorns']) }.to raise_error(SystemExit)
    end

    it 'includes gem generators in all_generator_names' do
      names = Belt::CLI::GenerateCommand.all_generator_names
      expect(names).to include('messaging')
      expect(names).to include('scaffold')
    end
  end

  describe 'DestroyCommand' do
    it 'delegates to the gem generator destroy method' do
      Belt::CLI::DestroyCommand.run(['messaging', '--confirm'])
      expect(Belt::Generators::MessagingGenerator.last_destroy_args).to eq(['--confirm'])
    end

    context 'when the generator does not implement destroy' do
      before do
        File.write(File.join(generators_dir, 'readonly_generator.rb'), <<~RUBY)
          module Belt
            module Generators
              class ReadonlyGenerator
                def self.run(args); end
              end
            end
          end
        RUBY

        fake_spec = instance_double(Gem::Specification, gem_dir: gem_dir)
        allow(Gem).to receive(:loaded_specs).and_return({ 'belt-readonly' => fake_spec })
        Belt::CLI::GeneratorRegistry.reset!
      end

      after do
        if Belt::Generators.const_defined?(:ReadonlyGenerator)
          Belt::Generators.send(:remove_const, :ReadonlyGenerator)
        end
      end

      it 'prints an error and exits' do
        expect { Belt::CLI::DestroyCommand.run(['readonly']) }
          .to output(/does not support destroy/).to_stdout
          .and raise_error(SystemExit)
      end
    end
  end
end
