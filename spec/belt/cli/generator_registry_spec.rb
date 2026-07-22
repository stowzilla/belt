# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'belt/cli/generator_registry'

RSpec.describe Belt::CLI::GeneratorRegistry do
  before { described_class.reset! }

  after { described_class.reset! }

  describe '.discovered_generators' do
    it 'returns a hash' do
      expect(described_class.discovered_generators).to be_a(Hash)
    end

    it 'is memoized after first call' do
      first = described_class.discovered_generators
      second = described_class.discovered_generators
      expect(first).to equal(second)
    end

    context 'when a gem provides a generator file' do
      let(:gem_dir) { Dir.mktmpdir }
      let(:generators_dir) { File.join(gem_dir, 'lib/belt/generators') }

      before do
        FileUtils.mkdir_p(generators_dir)
        File.write(File.join(generators_dir, 'messaging_generator.rb'), <<~RUBY)
          module Belt
            module Generators
              class MessagingGenerator
                def self.run(args)
                  args
                end

                def self.destroy(args)
                  args
                end

                def self.description
                  "Install messaging infrastructure"
                end
              end
            end
          end
        RUBY

        fake_spec = instance_double(Gem::Specification, gem_dir: gem_dir)
        allow(Gem).to receive(:loaded_specs).and_return({ 'belt-messaging' => fake_spec })
      end

      after { FileUtils.rm_rf(gem_dir) }

      it 'discovers the generator' do
        expect(described_class.discovered_generators).to include('messaging')
      end

      it 'returns the generator class' do
        klass = described_class.discovered_generators['messaging']
        expect(klass).to eq(Belt::Generators::MessagingGenerator)
      end

      it 'includes the name in generator_names' do
        expect(described_class.generator_names).to include('messaging')
      end

      it 'finds the generator by name' do
        expect(described_class.find('messaging')).to eq(Belt::Generators::MessagingGenerator)
      end

      it 'returns nil for unknown generators' do
        expect(described_class.find('nonexistent')).to be_nil
      end
    end

    context 'when a gem has no generators directory' do
      before do
        gem_dir = Dir.mktmpdir
        fake_spec = instance_double(Gem::Specification, gem_dir: gem_dir)
        allow(Gem).to receive(:loaded_specs).and_return({ 'some-gem' => fake_spec })
      end

      it 'returns an empty hash' do
        expect(described_class.discovered_generators).to eq({})
      end
    end

    context 'when a generator file fails to load' do
      let(:gem_dir) { Dir.mktmpdir }
      let(:generators_dir) { File.join(gem_dir, 'lib/belt/generators') }

      before do
        FileUtils.mkdir_p(generators_dir)
        File.write(File.join(generators_dir, 'broken_generator.rb'), <<~RUBY)
          raise LoadError, "intentional breakage"
        RUBY

        fake_spec = instance_double(Gem::Specification, gem_dir: gem_dir)
        allow(Gem).to receive(:loaded_specs).and_return({ 'belt-broken' => fake_spec })
      end

      after { FileUtils.rm_rf(gem_dir) }

      it 'warns and skips the generator' do
        expect { described_class.discovered_generators }.to output(/Warning.*broken/).to_stderr
      end

      it 'does not include the broken generator' do
        silence_warnings { expect(described_class.discovered_generators).to eq({}) }
      end

      private

      def silence_warnings
        original_stderr = $stderr
        $stderr = StringIO.new
        yield
      ensure
        $stderr = original_stderr
      end
    end

    context 'when multiple gems provide generators' do
      let(:gem_dir_a) { Dir.mktmpdir }
      let(:gem_dir_b) { Dir.mktmpdir }

      before do
        [gem_dir_a, gem_dir_b].each { |d| FileUtils.mkdir_p(File.join(d, 'lib/belt/generators')) }

        File.write(File.join(gem_dir_a, 'lib/belt/generators/notifications_generator.rb'), <<~RUBY)
          module Belt
            module Generators
              class NotificationsGenerator
                def self.run(args); end
              end
            end
          end
        RUBY

        File.write(File.join(gem_dir_b, 'lib/belt/generators/payments_generator.rb'), <<~RUBY)
          module Belt
            module Generators
              class PaymentsGenerator
                def self.run(args); end
                def self.destroy(args); end
              end
            end
          end
        RUBY

        fake_spec_a = instance_double(Gem::Specification, gem_dir: gem_dir_a)
        fake_spec_b = instance_double(Gem::Specification, gem_dir: gem_dir_b)
        allow(Gem).to receive(:loaded_specs).and_return(
          'belt-notifications' => fake_spec_a,
          'belt-payments' => fake_spec_b
        )
      end

      after do
        FileUtils.rm_rf(gem_dir_a)
        FileUtils.rm_rf(gem_dir_b)
      end

      it 'discovers all generators' do
        expect(described_class.generator_names).to contain_exactly('notifications', 'payments')
      end
    end
  end

  describe '.reset!' do
    it 'clears the memoized generators' do
      described_class.discovered_generators # trigger memoization
      described_class.reset!

      # After reset, it re-discovers (returns fresh result)
      allow(Gem).to receive(:loaded_specs).and_return({})
      expect(described_class.discovered_generators).to eq({})
    end
  end
end
