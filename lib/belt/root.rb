# frozen_string_literal: true

module Belt
  def self.root
    @root ||= detect_root
  end

  def self.root=(path)
    @root = path
  end

  def self.detect_root
    dir = Dir.pwd
    loop do
      return dir if File.exist?(File.join(dir, 'infrastructure/routes.tf.rb'))

      parent = File.dirname(dir)
      break if parent == dir

      dir = parent
    end
    Dir.pwd
  end

  private_class_method :detect_root
end
