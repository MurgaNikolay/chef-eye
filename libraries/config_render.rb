unless defined?(ChefEyeCookbook::ConfigRender)
  module ChefEyeCookbook
    class ConfigRender
      attr_writer :source_mode
      MULTIPLY = [:chain, :trigger, :checks, :triggers, :check, :nocheck]
      FILTERED_KEYS = [:name, :group, :application, :type]
      KEY_MAP = {
        triggers: :trigger,
        checks: :check,
        processes: :process,
        groups: :group,
        contacts: :contact,
        nochecks: :nocheck,
        notriggers: :trigger
      }

      def initialize
        create_renderers_methods
      end

      def source_mode
        @source_mode ||= SOURCE_MODE_SYMBOLIZE_KEYS
      end

      def render_config(config)
        render_hash(config).join("\n")
      end

      def render_block(name, *args, block)
        ret = []
        params = args.size > 0 ? "(#{args.map(&:to_source).join(', ')})" : ''
        ret << "#{name}#{params} do"
        ret << render_hash(block)
        ret << 'end'
      end

      def render_hash(variable)
        ret = []
        variable = symbolize_keys(variable)
        variable = variable.delete_keys_recursive(FILTERED_KEYS, [:contacts, :contact])
        variable.each do |method, value|
          method = inflect(method)
          render_strategy = "render_#{method}".to_sym
          if self.respond_to?(render_strategy)
            ret.push send(render_strategy, value)
          else
            ret.push "#{method}(#{expand_args(value)})"
          end
        end
        ret.compact.flatten.map { |i| "  #{i}" }
      end

      def expand_args(args)
        args.is_a?(Array) ? args.map { |a| a.to_source(source_mode) }.join(', ') : args.to_source(source_mode)
      end

      def render_contact(value)
        value.each_with_object([]) do |(name, options), ret|
          options = symbolize_keys(options)
          args = []
          args.push((options[:name] || name).to_sym)
          args.push(options[:type].to_sym)
          args.push(options[:contact].to_s)
          args.push(options[:opts].to_h) if options[:opts]
          args.map! { |arg| arg.to_source(source_mode) }
          ret.push "contact(#{args.join(', ')})"
          ret
        end
      end

      def symbolize_keys(hash)
        ChefEyeCookbook::Utils.symbolize_keys(hash)
      end

      def inflect(key)
        return KEY_MAP[key] if KEY_MAP[key]
        key
      end

      def fetch_methods(opts)
        (opts.methods - Object.methods).reject { |m| m.to_s.end_with?('=', 'initialize', '~', '>', '<', '?') || m.to_s.start_with?('get_', 'set_') }.map! { |m| opts.method(m) }
      end

      def create_renderers_methods
        dsl = []
        dsl << fetch_methods(::Eye::Dsl::ConfigOpts.new)
        dsl << fetch_methods(::Eye::Dsl::ApplicationOpts.new)
        dsl << fetch_methods(::Eye::Dsl::ProcessOpts.new)
        dsl.flatten!
        dsl.each do |method|
          renderer_name = "render_#{method.name}".to_sym
          next if respond_to?(renderer_name)
          generate_block_renderers(method, renderer_name)
          generate_multiply_renderers(method, renderer_name)
          generate_general_renderers(method, renderer_name)
        end
      end

      def generate_general_renderers(method, renderer_name)
        return if method_with_block?(method)
        return if MULTIPLY.include?(method.name)
        parameters = method.parameters
        self.class.send(:define_method, renderer_name) do |args|
          params = if parameters.size > 0
            "(#{expand_args(args)})"
          else
            ''
          end
          method.name.to_s + params
        end
      end

      def generate_multiply_renderers(method, renderer_name)
        return if method_with_block?(method)
        return unless MULTIPLY.include?(method.name)
        # multiply called
        parameters = method.parameters
        self.class.send(:define_method, renderer_name) do |value|
          value.each_with_object([]) do |(name, arg), ret|
            params = if parameters.size > 1
              "#{name.to_source(source_mode)}, #{arg.to_source(source_mode)}"
            else
              arg.to_source(source_mode)
            end
            ret.push("#{method.name}(#{params})")
          end
        end
      end

      def generate_block_renderers(method, renderer_name)
        return unless method_with_block?(method)
        parameters = method.parameters
        if parameters.size > 1
          self.class.send(:define_method, renderer_name) do |value|
            value.each_with_object([]) do |(block_name, config), ret|
              ret << render_block(method.name, block_name, config)
            end
          end
        else
          self.class.send(:define_method, renderer_name) do |value|
            render_block(method.name, value)
          end
        end
      end

      def method_with_block?(method)
        method.parameters.flatten.include?(:block)
      end

      module Helpers
        def renderer
          @renderer ||= ConfigRender.new
        end

        def render_config(config)
          renderer.render_config(config)
        end
      end
    end
  end

  class Object
    SOURCE_MODE_SYMBOLIZE_KEYS = :symbolize_keys
    SOURCE_MODE_DEFAULT = false

    def to_source(_mode = SOURCE_MODE_DEFAULT)
      to_s
    end
  end

  class Hash
    def to_source(mode = SOURCE_MODE_DEFAULT)
      items = each_with_object([]) do |(key, value), i|
        key = key.to_sym if mode == SOURCE_MODE_SYMBOLIZE_KEYS
        i.push "#{key.to_source(mode)} => #{value.to_source(mode)}"
      end
      "{#{items.join(', ')}}"
    end

    def delete_keys_recursive(keys, leave = [])
      each_with_object({}) do |(k, v), h|
        next h if keys.include?(k)
        v = v.delete_keys_recursive(keys, leave) if v.is_a?(::Hash) && !leave.include?(k)
        h[k] = v
        h
      end
    end
  end

  class NilClass
    def to_source(_mode = SOURCE_MODE_DEFAULT)
      'nil'
    end
  end

  class String
    def to_source(_mode = SOURCE_MODE_DEFAULT)
      "'#{self}'"
    end
  end

  class Symbol
    def to_source(_mode = SOURCE_MODE_DEFAULT)
      ":#{self}"
    end
  end

  class Array
    def to_source(mode = SOURCE_MODE_DEFAULT)
      "[#{map { |i| i.to_source(mode) }.join(', ')}]"
    end
  end
end
