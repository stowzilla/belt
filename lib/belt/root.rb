# frozen_string_literal: true

module Belt
  def self.root
    @root ||= detect_root
  end

  def self.root=(path)
    @root = path
  end

  # Resolves the path to routes.rb, checking config/ first then legacy paths.
  def self.routes_file
    candidates = [
      File.join(root, 'config/routes.rb'),
      File.join(root, 'config/routes.tf.rb'),
      File.join(root, 'infrastructure/routes.tf.rb')
    ]
    candidates.find { |f| File.exist?(f) }
  end

  # Resolves the path to contracts.rb, checking config/ first then legacy paths.
  def self.contracts_file
    candidates = [
      File.join(root, 'config/contracts.rb'),
      File.join(root, 'config/contracts.tf.rb'),
      File.join(root, 'config/schema.tf.rb'),
      File.join(root, 'infrastructure/schema.tf.rb')
    ]
    candidates.find { |f| File.exist?(f) }
  end

  # Legacy alias for backward compatibility
  def self.schema_file
    contracts_file
  end

  # Resolves the lambda config directory.
  def self.lambda_config_dir
    File.join(root, 'config/lambda')
  end

  def self.detect_root
    dir = Dir.pwd
    loop do
      return dir if File.exist?(File.join(dir, 'config/routes.rb'))
      return dir if File.exist?(File.join(dir, 'config/routes.tf.rb'))
      return dir if File.exist?(File.join(dir, 'infrastructure/routes.tf.rb'))

      parent = File.dirname(dir)
      break if parent == dir

      dir = parent
    end
    Dir.pwd
  end

  private_class_method :detect_root
end
