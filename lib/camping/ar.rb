class MissingLibrary < Exception #:nodoc: all
end
begin
    require 'active_record'
rescue LoadError => e
    raise MissingLibrary, "ActiveRecord could not be loaded (is it installed?): #{e.message}"
end

$AR_EXTRAS = %{
  Base = ActiveRecord::Base unless const_defined? :Base
  class SchemaInfo < Base
  end

  def self.V(n)
    @final = [n, @final.to_f].max
    m = (@migrations ||= [])
    Class.new(ActiveRecord::Migration) do
      meta_def(:version) { n }
      meta_def(:inherited) { |k| m << k }
    end
  end
  
  def self.create_schema(opts = {})
    opts[:assume] ||= -2
    opts[:version] ||= @final

    if @migrations
      unless SchemaInfo.table_exists?
        ActiveRecord::Schema.define do
          create_table SchemaInfo.table_name do |t|
            t.column :version, :float
          end
        end
      end

      si = SchemaInfo.find(:first) || SchemaInfo.new(:version => opts[:assume])
      if si.version < opts[:version]
        @migrations.each do |k|
          k.migrate(:up) if si.version < k.version and k.version <= opts[:version]
          k.migrate(:down) if si.version > k.version and k.version > opts[:version]
        end
        si.update_attributes(:version => opts[:version])
      end
    end
  end

  \# Since classes can't take blocks, we use a function that looks like the Base class
  \# and then define a derivative of Base on the fly.  We can then tie the model that
  \# inherits our singleton to the block of code the user gave for table creation.
  \# Presto! a migration pops into existence for each model we create.
  \# 
  \# So long as new models are added after existing models, we should correctly keep
  \# adding them in.
  \# 
  \# When you finally need a non-destructive table change adding a migration with a positive
  \# number will run as expected, but will preclude further automatic table creation. :(
  def self.Base(opts={}, &block)
    @final = -2 if @final.nil?	
	v = V -1.0/(1+(@migrations ||= []).size)
    Class.new(Base) do  
	  @abstract_class = true
	  @V = v
	  meta_def(:inherited) do |model|
	    Class.new(@V) do
		  @model = model; @opts = opts; @block = block
          def self.up
            q = []
            later = Proc.new do |attributes, &b|
              q << [attributes, b]
            end
			create_table @model.table_name, @opts do |t|
			  (class << t; self; end).class_eval do define_method(:create, &later); end
			  @block.call t
			end
            q.each do |attributes, b|
              @model.create attributes, &b
			end
		  end
		  def self.down
		    drop_table @model.table_name
		  end
		end
		super
	  end
	end
  end
}

$AR_CREATE = %{
  \# We assume that if they've defined a create method, they will handle wether or not to ask for a migration check.
  unless method_defined? :create
    def self.create
      Models.create_schema
    end
  end
}

module Camping
  module Models
    A = ActiveRecord
    # Base is an alias for ActiveRecord::Base.  The big warning I'm going to give you
    # about this: *Base overloads table_name_prefix.*  This means that if you have a
    # model class Blog::Models::Post, it's table name will be <tt>blog_posts</tt>.
    #
    # ActiveRecord is not loaded if you never reference this class.  The minute you
    # use the ActiveRecord or Camping::Models::Base class, then the ActiveRecord library
    # is loaded.
	Base = A::Base

    # The default prefix for Camping model classes is the topmost module name lowercase
    # and followed with an underscore.
    #
    #   Tepee::Models::Page.table_name_prefix
    #     #=> "tepee_pages"
    #
    def Base.table_name_prefix
        "#{name[/\w+/]}_".downcase.sub(/^(#{A}|camping)_/i,'')
    end
    module_eval $AR_EXTRAS
  end
end
Camping::S.sub! /autoload\s*:Base\s*,\s*['"]camping\/ar['"]\s*;?\s*end/, "#{$AR_EXTRAS}\n\tend\n#{$AR_CREATE}"
Camping::Apps.each do |c|
  c::Models.module_eval $AR_EXTRAS
  c.module_eval $AR_CREATE
end
