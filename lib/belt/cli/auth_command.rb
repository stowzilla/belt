# frozen_string_literal: true

require 'fileutils'
require 'erb'
require_relative 'app_detection'

module Belt
  module CLI
    class AuthCommand
      TEMPLATE_DIR = File.expand_path('../../templates/generate/auth', __dir__)
      MODULE_DIR = 'infrastructure/modules/app'

      include AppDetection

      def self.run(args)
        if args.include?('--help') || args.include?('-h')
          print_help
          exit 0
        end

        force = args.delete('--force') || args.delete('-f')
        signup = args.delete('--signup')
        pools = parse_pools(args)

        new(pools: pools, force: force, signup: signup).generate
      end

      def self.destroy(_args)
        new(pools: [], force: false).remove
      end

      def self.print_help
        puts <<~HELP
          Generate Cognito user pool infrastructure for authentication.

          Usage: belt generate auth [pool_names...] [options]

          Options:
            --signup        Allow public user registration (generates frontend views)
            --force, -f     Overwrite existing cognito.tf (skip collision check)

          Arguments:
            pool_names      Optional pool names for multiple user pools.
                            If omitted, generates a single pool named "main".

          Examples:
            belt g auth                        # Admin-only, single pool
            belt g auth --signup               # Public signup with frontend views
            belt g auth web                    # Named pool: "web"
            belt g auth web mobile             # Two pools
            belt g auth --force                # Overwrite existing

          What this generates:
            infrastructure/modules/app/cognito.tf          User pool + client resources
            infrastructure/modules/app/cognito_outputs.tf  Pool ID, ARN, and client ID outputs

          With --signup (when frontend/ exists):
            frontend/src/lib/auth.js                       Auth module (signIn, signUp, etc.)
            frontend/src/lib/apiClient.js                  API client with Authorization header
            frontend/src/pages/auth/Login.jsx              Login page
            frontend/src/pages/auth/SignUp.jsx             Registration page
            frontend/src/pages/auth/ConfirmEmail.jsx       Email verification page
            frontend/src/components/ProtectedRoute.jsx     Route guard component

          Without --signup (admin-only, default):
            frontend/src/lib/auth.js                       Auth module (signIn only)
            frontend/src/lib/apiClient.js                  API client with Authorization header
            frontend/src/pages/auth/Login.jsx              Login page
            frontend/src/components/ProtectedRoute.jsx     Route guard component

          It also patches:
            infrastructure/modules/app/main.tf             Adds cognito_user_pool_arns to conveyor_belt

          After running:
            1. Review the generated Cognito config in cognito.tf
            2. Add auth: :cognito to your routes namespace
            3. Run `belt deploy` to create the user pool
            4. Create your account (admin-only): aws cognito-idp admin-create-user ...
        HELP
      end

      # Parse pool names from args. Default to ["main"] if none provided.
      def self.parse_pools(args)
        names = args.reject { |a| a.start_with?('-') }
        names = ['main'] if names.empty?
        names.map(&:downcase).map { |n| n.gsub(/[^a-z0-9_]/, '_') }
      end

      def initialize(pools:, force: false, signup: false)
        @pool_names = pools
        @force = force
        @signup = signup
        @app_name = detect_app_name
        @pools = build_pool_metadata
      end

      def generate
        check_collision! unless @force
        ensure_module_dir!

        write_cognito_tf
        write_cognito_outputs_tf
        patch_main_tf
        patch_env_outputs
        generate_frontend_auth if frontend?

        puts "\n✓ Auth generated!"
        print_next_steps
      end

      def print_next_steps
        puts "\nNext steps:"
        puts '  1. Add auth: :cognito to your routes namespace:'
        puts ''
        puts '       namespace :api, auth: :cognito do'
        puts '         # your resources...'
        puts '       end'
        puts ''
        if frontend?
          puts '  2. Wire auth into your frontend/src/App.jsx:'
          puts ''
          puts "       import Login from './pages/auth/Login'"
          puts "       import ProtectedRoute from './components/ProtectedRoute'"
          puts ''
          puts '       // Add login route:'
          puts '       <Route path="/login" element={<Login onLogin={() => window.location.href = \'/\'} />} />'
          puts ''
          puts '       // Wrap protected routes:'
          puts '       <Route path="/*" element={<ProtectedRoute><YourApp /></ProtectedRoute>} />'
          puts ''
          puts '  3. Deploy: belt deploy'
          print_create_user_step(4) unless @signup
        else
          puts '  2. Deploy: belt deploy'
          print_create_user_step(3) unless @signup
        end
      end

      def print_create_user_step(step_num)
        puts "  #{step_num}. Create your account:"
        puts '       aws cognito-idp admin-create-user \\'
        puts '         --user-pool-id <pool-id-from-terraform-output> \\'
        puts '         --username your@email.com \\'
        puts '         --temporary-password TempPass123 \\'
        puts '         --message-action SUPPRESS'
      end

      def remove
        removed = []

        cognito_tf = File.join(MODULE_DIR, 'cognito.tf')
        cognito_outputs_tf = File.join(MODULE_DIR, 'cognito_outputs.tf')

        if File.exist?(cognito_tf)
          FileUtils.rm(cognito_tf)
          removed << cognito_tf
          puts "  remove  #{cognito_tf}"
        end

        if File.exist?(cognito_outputs_tf)
          FileUtils.rm(cognito_outputs_tf)
          removed << cognito_outputs_tf
          puts "  remove  #{cognito_outputs_tf}"
        end

        unpatch_main_tf
        removed << File.join(MODULE_DIR, 'main.tf') if @main_tf_patched

        if removed.empty?
          puts '  Nothing to remove — auth was not generated.'
        else
          puts "\n✓ Auth destroyed!"
        end
      end

      private

      def build_pool_metadata
        if @pool_names.length == 1 && @pool_names.first == 'main'
          [{ name: 'main', suffix: '', label: '' }]
        else
          @pool_names.map do |name|
            { name: name, suffix: "-#{name}", label: " (#{name})" }
          end
        end
      end

      def frontend?
        Dir.exist?('frontend/src')
      end

      def generate_frontend_auth
        frontend_template_dir = File.join(TEMPLATE_DIR, 'frontend')

        # Generate auth lib files
        lib_dir = 'frontend/src/lib'
        FileUtils.mkdir_p(lib_dir)
        copy_frontend_file(frontend_template_dir, 'auth.js', File.join(lib_dir, 'auth.js'))
        copy_frontend_file(frontend_template_dir, 'apiClient.js', File.join(lib_dir, 'apiClient.js'))

        pages_dir = 'frontend/src/pages/auth'
        FileUtils.mkdir_p(pages_dir)
        copy_frontend_file(frontend_template_dir, 'Login.jsx', File.join(pages_dir, 'Login.jsx'))
        copy_frontend_file(frontend_template_dir, 'auth.css', File.join(pages_dir, 'auth.css'))
        if @signup
          # Generate auth pages
          copy_frontend_file(frontend_template_dir, 'SignUp.jsx', File.join(pages_dir, 'SignUp.jsx'))
          copy_frontend_file(frontend_template_dir, 'ConfirmEmail.jsx', File.join(pages_dir, 'ConfirmEmail.jsx'))
        end

        # Generate ProtectedRoute component
        components_dir = 'frontend/src/components'
        FileUtils.mkdir_p(components_dir)
        copy_frontend_file(frontend_template_dir, 'ProtectedRoute.jsx',
                           File.join(components_dir, 'ProtectedRoute.jsx'))

        install_cognito_sdk
      end

      def copy_frontend_file(template_dir, filename, dest)
        src = File.join(template_dir, filename)
        FileUtils.cp(src, dest)
        puts "  create  #{dest}"
      end

      def install_cognito_sdk
        puts "\n  Installing @aws-sdk/client-cognito-identity-provider..."
        success = system('npm', 'install', '@aws-sdk/client-cognito-identity-provider',
                         '--prefix', 'frontend', '--no-fund', '--no-audit', '--silent')
        if success
          puts '  ✓      npm dependency installed'
        else
          puts '  ⚠      npm install failed — run: cd frontend && npm install @aws-sdk/client-cognito-identity-provider'
        end
      end

      def check_collision!
        cognito_tf = File.join(MODULE_DIR, 'cognito.tf')
        return unless File.exist?(cognito_tf)

        puts "\n✗ Auth already exists at #{cognito_tf}"
        puts "\nTo overwrite, run again with --force:"
        puts "  belt g auth #{@pool_names.join(' ')} --force"
        exit 1
      end

      def ensure_module_dir!
        FileUtils.mkdir_p(MODULE_DIR)
      end

      def write_cognito_tf
        dest = File.join(MODULE_DIR, 'cognito.tf')
        write_template('cognito.tf.erb', dest)
        puts "  create  #{dest}"
      end

      def write_cognito_outputs_tf
        dest = File.join(MODULE_DIR, 'cognito_outputs.tf')
        write_template('cognito_outputs.tf.erb', dest)
        puts "  create  #{dest}"
      end

      def patch_main_tf
        main_tf = File.join(MODULE_DIR, 'main.tf')
        return unless File.exist?(main_tf)

        content = File.read(main_tf)

        if content.include?('cognito_user_pool_arns')
          puts "  skip    #{main_tf} (cognito_user_pool_arns already present)"
          return
        end

        return unless content.match?(/^resource "conveyor_belt"/)

        arns = @pools.map { |p| "aws_cognito_user_pool.#{p[:name]}.arn" }
        arn_value = build_arn_value(arns)

        insert_cognito_into_resource(content, main_tf, arn_value)
      end

      def patch_env_outputs
        env_dirs = Dir.glob('infrastructure/*/outputs.tf')
                      .reject { |f| f.include?('modules') }

        env_dirs.each do |outputs_file|
          content = File.read(outputs_file)

          next if content.include?('cognito_user_pool_id')

          cognito_outputs = @pools.map do |pool|
            suffix = pool[:suffix]
            <<~HCL

              output "cognito_user_pool_id#{suffix}" {
                description = "Cognito User Pool ID#{pool[:label]}"
                value       = module.app.cognito_user_pool_id#{suffix}
              }

              output "cognito_client_id#{suffix}" {
                description = "Cognito User Pool Client ID#{pool[:label]}"
                value       = module.app.cognito_client_id#{suffix}
              }

              output "cognito_region" {
                description = "AWS region for Cognito"
                value       = var.aws_region
              }
            HCL
          end.join

          File.write(outputs_file, content + cognito_outputs)
          env_name = File.basename(File.dirname(outputs_file))
          puts "  update  #{outputs_file} (added cognito outputs for #{env_name})"
        end
      end

      def build_arn_value(arns)
        if arns.length == 1
          "[#{arns.first}]"
        else
          "[\n    #{arns.join(",\n    ")}\n  ]"
        end
      end

      def insert_cognito_into_resource(content, main_tf, arn_value)
        lines = content.lines
        brace_depth = 0
        insert_index = nil
        in_resource = false

        lines.each_with_index do |line, idx|
          if line.match?(/^resource "conveyor_belt"/)
            in_resource = true
            brace_depth = 0
          end

          next unless in_resource

          brace_depth += line.count('{') - line.count('}')

          next unless brace_depth <= 0

          insert_index = idx
          break
        end

        return unless insert_index

        cognito_line = "\n  cognito_user_pool_arns = #{arn_value}\n"
        lines.insert(insert_index, cognito_line)
        File.write(main_tf, lines.join)
        puts "  update  #{main_tf} (added cognito_user_pool_arns)"
      end

      def unpatch_main_tf
        main_tf = File.join(MODULE_DIR, 'main.tf')
        @main_tf_patched = false
        return unless File.exist?(main_tf)

        content = File.read(main_tf)
        return unless content.include?('cognito_user_pool_arns')

        # Remove the cognito_user_pool_arns line(s) — could be single or multi-line
        updated = content.gsub(/\n\s*cognito_user_pool_arns\s*=\s*\[[^\]]*\]\n/, "\n")
        return if updated == content

        File.write(main_tf, updated)
        puts "  update  #{main_tf} (removed cognito_user_pool_arns)"
        @main_tf_patched = true
      end

      def write_template(template_name, dest_path)
        template_path = File.join(TEMPLATE_DIR, template_name)
        content = ERB.new(File.read(template_path), trim_mode: '-').result(binding)
        File.write(dest_path, content)
      end
    end
  end
end
