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
    if @magicMigrations
	  m = (@migrations ||= [])
	  @magicMigrations.each do |model, options, block|
		table = Object
		model.split(/::/u).each do |part| table = table.const_get(part); end 
	    Class.new(V -1.0/(1+m.size)) do
		  @options = options
          @block = block
		  @table = table
          def self.up
            queue = []
            later = Proc.new do |attributes, &b|
              queue << [attributes, b]
            end
			create_table @table.table_name, @options do |t|
			  (class << t; self; end).class_eval do define_method(:create, &later); end
			  @block.call t
			end
            queue.each do |attributes, b|
			  @table.create attributes, &b
			end
		  end
		  def self.down
		    drop_table @table.table_name
		  end
		end
	  end
	end
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

  def self.Base(opts={}, &block)
	m = (@magicMigrations ||= [])
    Class.new(Base) do  
	  @abstract_class = true
	  meta_def(:inherited) do |model|
	    m << [model.to_s, opts, block]
		super
	  end
	end
  end
}

$AR_CREATE = %{
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
