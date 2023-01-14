require 'redisize'

require "jsonize/version"

module Jsonize
   JSONIZE_ATTRS = {
      created_at: nil,
      updated_at: nil,
   }

   ORMS = {
      ActiveRecord: 'active_record'
   }

   def external_attrs options = {}
      if externals = options[:externals]
         externals.keys.map {|k| [k.to_sym, k.to_sym] }.to_h
      else
         {}
      end
   end

   def instance_attrs
      self.attribute_names.map {|a| [a.to_sym, true] }.to_h
   end

   def embed_attrs
      begin
         self.class.const_get("JSONIZE_ATTRS")
      rescue
         {}
      end
   end

   def additional_attrs
      attributes = self.instance_variable_get(:@attributes).send(:attributes)

      if attributes.is_a?(ActiveModel::LazyAttributeHash)
         attributes.send(:additional_types)
      elsif attributes.is_a?(Hash)
         attributes
      else
         raise
      end
   end

   def generate_json propses, options = {}
      propses.reduce({}) do |r, (name, props)|
         value =
            if props["rule"] == '_reflection'
               send(props["real_name"] || name).as_json(options[name.to_sym] || {})
            elsif props["rule"].is_a?(String) and options[:externals] # NOTE required for sidekiq key
               externals = options[:externals]
               externals.fetch(props["rule"].to_sym) { |x| externals[props["rule"]] }
            elsif props["real_name"] != name.to_s
               read_attribute(props["real_name"]).as_json
            elsif props["rule"].instance_variable_get(:@value)
               props["rule"].instance_variable_get(:@value)
            elsif props["rule"]
               read_attribute(props["real_name"] || props["rule"])
            end

         r.merge(name => value)
      end
   end

   def prepare_json options = {}
      attr_hash = [
         instance_attrs,
         JSONIZE_ATTRS,
         embed_attrs,
         additional_attrs,
         options[:map] || {},
         _reflections,
         external_attrs(options)
      ].reduce { |r, hash| r.merge(hash.map {|k,v| [k.to_sym, v] }.to_h) }
      except = options.fetch(:except, [])
      only = options.fetch(:only, self.attributes.keys.map(&:to_sym) | (options[:map] || {}).keys | embed_attrs.keys | external_attrs(options).keys)

      attr_hash.map do |(name_in, rule_in)|
         name = /^_(?<_name>.*)/ =~ name_in && _name || name_in.to_s

         next nil if except.include?(name.to_sym) || (only & [ name.to_sym, name_in.to_sym ].uniq).blank?

         rule = parse_rule(rule_in)
         next unless rule

         [name, { "rule" => rule, "real_name" => name_in.to_s }]
      end.compact.to_h
   end

   def parse_rule rule_in
      case rule_in.class.to_s
      when /^(True|False|Nil)Class$/
         true
      when /::Reflection::/ # "ActiveRecord::Reflection::AbstractReflection"
         '_reflection'
      when /^(Symbol|String)$/
         rule_in.to_s
      when "ActiveModel::Attribute::Uninitialized"
         false
      else
         true
      end
   end

   def jsonize options = {}
      attr_props = prepare_json(options)
      redisize_json(attr_props) do
         generate_json(attr_props, options)
      end
   end

   def dejsonize options = {}
      attr_props = prepare_json(options)
      deredisize_json(attr_props)
   end

   def as_json options = {}
      attr_props = prepare_json(options)
      generate_json(attr_props, options)
   end

   module Relation
      def jsonize context = {}
         redisize_sql do
            all.as_json(context)
         end
      end

      def find_by_slug slug
         redisize_model(slug, by_key: :slug) do
            self.joins(:slug).where(slugs: {text: slug}).first
         end
      end

      def find_by_pk primary_key_value
         redisize_model(primary_key_value) do
            self.where(self.primary_key => primary_key_value).first
         end
      end
   end

   class << self
      def included kls
         kls.include(Redisize)
      end

      def detect_orm
         Object.constants.each do |anc|
            orm = ORMS.keys.find {|re| /#{re}/ =~ anc.to_s }
            require("jsonize/orm/#{ORMS[orm]}") if orm
         end
      end
   end

   self.detect_orm
end
