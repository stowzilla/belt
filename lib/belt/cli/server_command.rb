# frozen_string_literal: true

require 'base64'
require 'json'
require_relative 'app_detection'
require_relative 'environment_config'
require_relative 'frontend_env_map'
require_relative 'frontend_registry'
require_relative 'terraform_command'

module Belt
  module CLI
    class ServerCommand
      include AppDetection

      DEFAULT_PORT = 3000

      def self.run(args)
        port = DEFAULT_PORT
        open_browser = false
        frontend_name = FrontendRegistry.extract_flag!(args, '--frontend')

        i = 0
        while i < args.length
          case args[i]
          when '-p', '--port'
            i += 1
            port = args[i].to_i
          when /^--port=/
            port = args[i].split('=', 2).last.to_i
          when '-o', '--open'
            open_browser = true
          when '-h', '--help'
            puts help_text
            exit 0
          end
          i += 1
        end

        new(port: port, open_browser: open_browser, frontend_name: frontend_name).run
      end

      def self.help_text
        <<~HELP
          Start a local development server for the frontend.

          Usage: belt server [options]
                 belt s [options]

          Options:
            -p, --port PORT          Port to serve on (default: #{DEFAULT_PORT})
            --frontend NAME          Which frontend to start (when several exist)
            -o, --open               Open browser after starting
            -h, --help               Show this help

          Behavior:
            • If a frontend exists → runs its dev server (npx vite)
              Injects env from <frontend>/env.yml (or default VITE_API_URL) using
              terraform outputs when available.
            • If no frontend → serves the welcome page via a local HTTP server
              After deploy, shows live API URL and deployment status.

          Note: The backend is serverless (AWS Lambda). Use `belt deploy` to deploy
          your backend to AWS. Local frontend development reads the env map (or
          <frontend>/.env via `belt frontend env <env>`).

          Examples:
            belt server                      # Start on port #{DEFAULT_PORT}
            belt s -p 4000                   # Start on port 4000
            belt s --frontend ops            # Start the ops frontend
            belt s --open                    # Start and open browser
        HELP
      end

      def initialize(port:, open_browser: false, frontend_name: nil)
        @port = port
        @open_browser = open_browser
        @frontend_name = frontend_name
        @app_name = detect_app_name
        @api_url = detect_api_url
        @frontend = resolve_frontend
      end

      def run
        if @frontend&.exists?
          run_frontend_dev_server
        else
          run_welcome_server
        end
      end

      private

      def resolve_frontend
        registry = FrontendRegistry.new
        return nil if registry.empty? && @frontend_name.nil?

        registry.resolve!(@frontend_name)
      end

      def run_frontend_dev_server
        puts "🚀 Starting #{@frontend.label} dev server on port #{@port}..."
        build_env = frontend_process_env
        api_url = build_env['VITE_API_URL'] || build_env['REACT_APP_API_URL'] ||
                  build_env['NEXT_PUBLIC_API_URL'] || @api_url
        if api_url
          puts "   Backend API: #{api_url}"
        else
          puts '   Backend is serverless — deploy with `belt deploy` to set up AWS resources.'
        end
        puts "   Env: #{build_env.keys.sort.join(', ')}" if build_env.any?
        puts ''

        open_browser_later if @open_browser

        env = { 'PORT' => @port.to_s }.merge(build_env)

        # Prefer the dev script with the port flag for Vite-based setups
        Dir.chdir(@frontend.path) do
          exec(env, 'npx', 'vite', '--port', @port.to_s)
        end
      end

      # Process env from the declarative map (or default VITE_API_URL), if an env is available.
      def frontend_process_env
        env_name = @deploy_env || ENV.fetch('BELT_ENV', nil) || TerraformCommand.list_environments.first
        return {} unless env_name

        infra_dir = TerraformCommand.find_infrastructure_dir
        EnvironmentConfig.load(env_name, infra_dir: infra_dir).apply!

        FrontendEnvMap.new(env_name, frontend_path: @frontend.path).process_env
      rescue StandardError
        # Fall back to legacy api_url detection if map resolution fails
        @api_url ? { 'VITE_API_URL' => @api_url } : {}
      end

      def run_welcome_server
        puts "🚀 Serving Belt welcome page on http://localhost:#{@port}"
        if @api_url
          puts "   Backend API: #{@api_url}"
        else
          puts '   No deployment detected — showing pre-deploy welcome page.'
          puts '   Backend is serverless — deploy with `belt deploy` to set up AWS resources.'
        end
        puts ''
        puts '   Tip: Run `belt generate frontend react` to scaffold a frontend app.'
        puts ''

        require 'webrick'

        server = WEBrick::HTTPServer.new(Port: @port, Logger: WEBrick::Log.new(File::NULL), AccessLog: [])

        server.mount_proc '/' do |_req, res|
          res['Content-Type'] = 'text/html; charset=utf-8'
          res.body = welcome_html
        end

        open_browser_later if @open_browser

        trap('INT') { server.shutdown }
        trap('TERM') { server.shutdown }

        server.start
      end

      def gem_assets_dir
        @gem_assets_dir ||= File.expand_path('../assets', __dir__)
      end

      def welcome_html
        title = ENV.fetch('WELCOME_TITLE', 'Welcome to Belt')
        subtitle = ENV.fetch('WELCOME_SUBTITLE', 'Your app is ready. Deploy to see it live on AWS.')

        css = load_asset('welcome.css') || ''
        image_b64 = load_image_base64('belt-default.jpg') || ''

        if @api_url
          deployed_html(css: css, image_b64: image_b64)
        else
          pre_deploy_html(title: title, subtitle: subtitle, css: css, image_b64: image_b64)
        end
      end

      def load_asset(filename)
        path = File.join(gem_assets_dir, filename)
        File.exist?(path) ? File.read(path) : nil
      end

      def load_image_base64(filename)
        path = File.join(gem_assets_dir, filename)
        File.exist?(path) ? Base64.strict_encode64(File.binread(path)) : nil
      end

      def deployed_html(css:, image_b64:)
        <<~HTML
          <!DOCTYPE html>
          <html lang="en">
          <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>#{@app_name} — Deployed</title>
            <style>#{css}</style>
          </head>
          <body>
            <div class="hero">
              <img src="data:image/jpeg;base64,#{image_b64}" alt="Belt" class="hero-bg" />
              <div class="overlay">
                <h1>#{@app_name}</h1>
                <p class="subtitle">Deployed and running on AWS</p>
              </div>
            </div>
            <div class="container">
              <div class="next-steps">
                <h2>Next Steps</h2>
                <ol>
                  <li>View your live app: <a href="#{@api_url}">#{@api_url}</a> (#{@deploy_env || 'dev'})</li>
                  <li>Generate a resource: <code>belt g resource post title:string body:text</code></li>
                  <li>Set up a frontend: <code>belt generate frontend react</code></li>
                </ol>
              </div>
            </div>
          </body>
          </html>
        HTML
      end

      def pre_deploy_html(title:, subtitle:, css:, image_b64:)
        <<~HTML
          <!DOCTYPE html>
          <html lang="en">
          <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>#{title}</title>
            <style>#{css}</style>
          </head>
          <body>
            <div class="hero">
              <img src="data:image/jpeg;base64,#{image_b64}" alt="Belt" class="hero-bg" />
              <div class="overlay">
                <h1>#{title}</h1>
                <p class="subtitle">#{subtitle}</p>
              </div>
            </div>
            <div class="container">
              <div class="info">
                <p><strong>App:</strong> #{@app_name}</p>
                <p><strong>Status:</strong> Not yet deployed</p>
              </div>
              <div class="next-steps">
                <h2>Next Steps</h2>
                <ol>
                  <li>Generate a resource: <code>belt g resource post title:string body:text</code></li>
                  <li>Deploy to AWS: <code>belt deploy</code></li>
                  <li>Set up a frontend: <code>belt generate frontend react</code></li>
                </ol>
              </div>
            </div>
          </body>
          </html>
        HTML
      end

      # Reads terraform outputs to find the deployed API URL.
      # Checks all available environments, preferring BELT_ENV.
      def detect_api_url
        infra_dir = TerraformCommand.find_infrastructure_dir
        return nil unless infra_dir

        # Prefer BELT_ENV, then try each environment
        envs = TerraformCommand.list_environments
        preferred = ENV.fetch('BELT_ENV', nil)
        envs.unshift(envs.delete(preferred)) if preferred && envs.include?(preferred)

        envs.each do |env|
          env_dir = File.join(infra_dir, env)
          next unless Dir.exist?(env_dir)
          next unless File.exist?(File.join(env_dir, '.terraform'))

          EnvironmentConfig.load(env, infra_dir: infra_dir).apply!
          url = read_api_url_from_outputs(env_dir)
          if url
            @deploy_env = env
            return url
          end
        end

        nil
      end

      def read_api_url_from_outputs(env_dir)
        output = nil
        Dir.chdir(env_dir) do
          # Use Open3 to check exit status — terraform writes errors to stdout too
          require 'open3'
          output, status = Open3.capture2('terraform', 'output', '-json', err: File::NULL)
          return nil unless status.success?
        end
        return nil if output.nil? || output.strip.empty?

        data = JSON.parse(output.strip)

        # api_url output is a map like { "app_name" => "https://..." }
        if data['api_url'] && data['api_url']['value']
          value = data['api_url']['value']
          case value
          when String
            value
          when Hash
            # Take the first URL from the map
            value.values.first
          end
        end
      rescue JSON::ParserError, Errno::ENOENT
        nil
      end

      def open_browser_later
        Thread.new do
          sleep 1.5
          url = "http://localhost:#{@port}"
          if RUBY_PLATFORM.include?('darwin')
            system('open', url)
          elsif RUBY_PLATFORM.include?('linux')
            system('xdg-open', url, out: File::NULL, err: File::NULL)
          end
        end
      end
    end
  end
end
