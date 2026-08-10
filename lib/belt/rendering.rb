# frozen_string_literal: true

require 'erb'
require 'cgi'

module Belt
  # Provides Rails-like ERB rendering for BeltController.
  #
  # Convention: templates live at `views/<controller_name>/<action>.html.erb`
  # relative to the controller's gem or app directory.
  #
  # Usage:
  #   class WelcomeController < BeltController::Base
  #     def show
  #       @title = "Hello"
  #       render  # auto-resolves to views/welcome/show.html.erb
  #     end
  #   end
  #
  # Or explicit:
  #   render template: "welcome/show"
  #   render inline: "<h1><%= @title %></h1>"
  #
  module Rendering
    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      # Override in subclasses to set a custom view path.
      # Defaults to `views/` relative to the file that defines the controller.
      def view_paths
        @view_paths ||= []
      end

      def prepend_view_path(path)
        view_paths.unshift(path)
      end

      def append_view_path(path)
        view_paths << path
      end
    end

    private

    # Render an ERB template and return an html_response.
    #
    # Options:
    #   render                         — auto-resolve from controller/action
    #   render template: "ctrl/action" — explicit template path (no extension)
    #   render inline: "<%= @x %>"     — render a string as ERB
    #   render status: 201             — custom status code
    #   render layout: false           — skip layout (default: no layout)
    #
    def render(options = {})
      # Status may be Integer or Symbol (:created, :ok, …)
      status = options.fetch(:status, 200)

      html = if options.key?(:inline)
               render_erb_string(options[:inline])
             else
               template_path = resolve_template_path(options[:template])
               render_erb_file(template_path)
             end

      html_response(html, status)
    end

    def render_erb_string(source)
      erb = ERB.new(source, trim_mode: '-')
      erb.result(binding)
    end

    def render_erb_file(path)
      raise Belt::TemplateNotFound, "Template not found: #{path}" unless File.exist?(path)

      source = File.read(path)
      erb = ERB.new(source, trim_mode: '-')
      erb.filename = path
      erb.result(binding)
    end

    # HTML-escape helper, available in templates as `h(value)`
    def h(text)
      CGI.escapeHTML(text.to_s)
    end

    def resolve_template_path(explicit_template = nil)
      template_name = explicit_template || default_template_name
      search_paths = build_view_search_paths

      search_paths.each do |base|
        full_path = File.join(base, "#{template_name}.html.erb")
        return full_path if File.exist?(full_path)
      end

      # If nothing found, return the first candidate so the error message is useful
      File.join(search_paths.first || '.', "#{template_name}.html.erb")
    end

    def default_template_name
      # PostsController → posts, Belt::WelcomeController → welcome
      controller = self.class.name.split('::').last
                       .sub(/Controller$/, '')
                       .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
                       .gsub(/([a-z\d])([A-Z])/, '\1_\2')
                       .downcase
      "#{controller}/#{action_name}"
    end

    def build_view_search_paths
      paths = []

      # 1. Class-level view paths (set by the controller or gem)
      paths.concat(self.class.view_paths) if self.class.respond_to?(:view_paths)

      # 2. Walk up the class hierarchy for inherited view paths
      klass = self.class.superclass
      while klass.respond_to?(:view_paths)
        paths.concat(klass.view_paths)
        klass = klass.superclass
      end

      # 3. App-level views (convention: lambda/views/ from Belt.root)
      if defined?(Belt.root) && Belt.root
        paths << File.join(Belt.root, 'lambda', 'views')
        paths << File.join(Belt.root, 'views')
      end

      # 4. Gem-level fallback (views/ relative to this file — belt gem's own views)
      paths << File.expand_path('views', __dir__)

      paths.uniq
    end
  end
end
