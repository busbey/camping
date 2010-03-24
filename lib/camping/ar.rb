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
    @final = [n, @final.to_i].max
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

  def self.binding binding; end
  def self.Base(opts={}, &block)
	m = (@migrations ||= [])
	v = Proc.new do |arg| V arg end
    Class.new(Base) do  
	  meta_def(:inherited) do |model|
	    b = Proc.new do |t|  block.call t end
	    Class.new(v.call(-1/(1+m.size))) do
		  @table = eval("\#{model.to_s} = Class.new(Base)", self.binding)
		  @block = b
		  @queue = Array.new
		  def self.up
		    create_table @table.table_name do |t| 
			  later = Proc.new do |entry| @queue << entry; end
			  def t.create attributes, &block
			    later.call([attributes, block])
		  	  end
			  @block.call t 
			end
			@queue.each do |entry|
			  @table.create *entry
			end
		  end
		  def self.down
		    drop_table @table.table_name
		  end
		end
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
