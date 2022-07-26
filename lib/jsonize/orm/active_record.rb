require 'active_support/lazy_load_hooks'

ActiveSupport.on_load :active_record do
   ::ActiveRecord::Base.send :include, Jsonize
   ::ActiveRecord::Relation.send :include, Jsonize::Relation

#    included do
#      # Existing subclasses pick up the model extension as well
#      descendants.each do |kls|
#        kls.send(:include, Kaminari::ActiveRecordModelExtension) if kls.superclass == ::ActiveRecord::Base
#      end
#    end

end
