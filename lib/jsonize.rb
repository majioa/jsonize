require 'redisize'

require "jsonize/version"

module Jsonize
   DEFAULT_EXCEPT_ATTRS = [:created_at, :updated_at]

   JSONIZE_ATTRS = {
      created_at: nil,
      updated_at: nil,
   }

   ORMS = {
      ActiveRecord: 'active_record'
   }

   JSON_TYPES = [String, Integer, TrueClass, FalseClass, NilClass, Hash, Array]

   def default_except_attributes
      DEFAULT_EXCEPT_ATTRS
   end

   # TODO where is the addtional sources for attributes
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

   def generate_relation rela, source_in, options
      source = source_in.is_a?(Hash) ? source_in : source_in.polymorphic? ?
         {} : required_attibutes(source_in.klass, {})

      case rela
      when Enumerable
         rela.map do |rec|
            generate_json(rec, source, options)
         end
      when NilClass
         nil
      when Object
         generate_json(rela, source, options)
      end
   end

   def generate_json flow, attr_props, options = {}
     in_h = (options[:externals] || {}).map {|(x, y)| [x.to_s, y] }.to_h

     attr_props.reduce(in_h) do |cr, (name, props)|
         value =
            [props].flatten.reduce(nil) do |r, source|
               case source
               when UnboundMethod
                  r || source.bind(flow)[]
               when Proc
                  r || source[flow]
               when Hash, ActiveRecord::Reflection::AbstractReflection
                  generate_relation(r || flow.send(name), source, options)
               else
                  raise
               end
            end

         cr.merge(name.to_s => proceed_value(value))
      end
   end

   def proceed_value value_in
      (value_in.class.ancestors & JSON_TYPES).any? ? value_in : value_in.to_s
   end

   def prepare_attributes model, attrs
      attrs.reduce({}) do |h, x|
         if x.is_a?(Hash)
            x.reduce(h) do |hh, (sub, subattrs)|
               if submodel = model._reflections[sub]&.klass
                  hh.merge(sub.to_sym => prepare_attributes(submodel, subattrs))
               else
                  hh
               end
            end
         else
            props = [
               model._reflections[x.to_s],
               model.instance_methods.include?(x.to_sym) ? model.instance_method(x.to_sym) : nil,
               (self.class == model ? self.attribute_names : model.attribute_names).
                  include?(x.to_s) ? ->(this) { this.read_attribute(x) } : nil
            ].compact

            h.merge(x.to_s.sub(/^_/, '').to_sym => props)
         end
      end
   end

   def attibute_tree klass, options = {}
      options[:only] ||
      jsonize_attributes_except(self.class == klass ? self.attribute_names : klass.attribute_names,
         options[:except] || default_except_attributes)
   end

   def jsonize_scheme_for klass, attr_tree
      jsonize_schemes[attr_tree] ||= prepare_attributes(klass, attr_tree)
   end

   def jsonize_attributes_except a_in, except_in
      except_in.reduce(a_in) do |res, name|
         if res.include?(name)
            res.delete(name)
         end

         res
      end
   end

   def jsonize_schemes
      schemes = self.class.instance_variable_get(:@jsonize_schemes) || {}
      self.class.instance_variable_set(:@jsonize_schemes, schemes)

      schemes
   end

   def primary_key
      @primary_key
   end

   def jsonize options = {}
      attr_tree = attibute_tree(self.class, options)

      redisize_json(attr_tree) do
         attr_props = jsonize_scheme_for(self.class, attr_tree)
         generate_json(self, attr_props, options)
      end
   end

   def dejsonize options = {}
      attr_tree = attibute_tree(self.class, options)
      deredisize_json(attr_tree)
   end

   def as_json options = {}
      attr_props = jsonize_scheme_for(self.class, attibute_tree(self.class, options))

      generate_json(self, attr_props, options)
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
