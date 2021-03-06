require 'tiny_tds'
Sequel.require 'adapters/shared/mssql'

module Sequel
  module TinyTDS
    class Database < Sequel::Database
      include Sequel::MSSQL::DatabaseMethods
      set_adapter_scheme :tinytds

      # Choose whether to use unicode strings on initialization
      def initialize(*)
        super
        set_mssql_unicode_strings
      end
      
      # Transfer the :user option to the :username option.
      def connect(server)
        opts = server_opts(server)
        opts[:username] = opts[:user]
        c = TinyTds::Client.new(opts)

        if (ts = opts[:textsize])
          sql = "SET TEXTSIZE #{typecast_value_integer(ts)}"
          log_yield(sql){c.execute(sql)}
        end
      
        c
      end
      
      # Execute the given +sql+ on the server.  If the :return option
      # is present, its value should be a method symbol that is called
      # on the TinyTds::Result object returned from executing the
      # +sql+.  The value of such a method is returned to the caller.
      # Otherwise, if a block is given, it is yielded the result object.
      # If no block is given and a :return is not present, +nil+ is returned.
      def execute(sql, opts={})
        synchronize(opts[:server]) do |c|
          begin
            m = opts[:return]
            r = nil
            if (args = opts[:arguments]) && !args.empty?
              types = []
              values = []
              args.each_with_index do |(k, v), i|
                v, type = ps_arg_type(v)
                types << "@#{k} #{type}"
                values << "@#{k} = #{v}"
              end
              case m
              when :do
                sql = "#{sql}; SELECT @@ROWCOUNT AS AffectedRows"
                single_value = true
              when :insert
                sql = "#{sql}; SELECT CAST(SCOPE_IDENTITY() AS bigint) AS Ident"
                single_value = true
              end
              sql = "EXEC sp_executesql N'#{c.escape(sql)}', N'#{c.escape(types.join(', '))}', #{values.join(', ')}"
              log_yield(sql) do
                r = c.execute(sql)
                r.each{|row| return row.values.first} if single_value
              end
            else
              log_yield(sql) do
                r = c.execute(sql)
                return r.send(m) if m
              end
            end
            yield(r) if block_given?
          rescue TinyTds::Error => e
            raise_error(e, :disconnect=>!c.active?)
          ensure
           r.cancel if r && c.sqlsent?
          end
        end
      end

      # Return the number of rows modified by the given +sql+.
      def execute_dui(sql, opts={})
        execute(sql, opts.merge(:return=>:do))
      end

      # Return the value of the autogenerated primary key (if any)
      # for the row inserted by the given +sql+.
      def execute_insert(sql, opts={})
        execute(sql, opts.merge(:return=>:insert))
      end

      # Execute the DDL +sql+ on the database and return nil.
      def execute_ddl(sql, opts={})
        execute(sql, opts.merge(:return=>:each))
        nil
      end

      private

      # For some reason, unless you specify a column can be
      # NULL, it assumes NOT NULL, so turn NULL on by default unless
      # the column is a primary key column.
      def column_list_sql(g)
        pks = []
        g.constraints.each{|c| pks = c[:columns] if c[:type] == :primary_key} 
        g.columns.each{|c| c[:null] = true if !pks.include?(c[:name]) && !c[:primary_key] && !c.has_key?(:null) && !c.has_key?(:allow_null)}
        super
      end

      # tiny_tds uses TinyTds::Error as the base error class.
      def database_error_classes
        [TinyTds::Error]
      end

      # Close the TinyTds::Client object.
      def disconnect_connection(c)
        c.close
      end

      # Return true if the :conn argument is present and not active.
      def disconnect_error?(e, opts)
        super || (opts[:conn] && !opts[:conn].active?)
      end

      # Return a 2 element array with the literal value and type to use
      # in the prepared statement call for the given value and connection.
      def ps_arg_type(v)
        case v
        when Fixnum
          [v, 'int']
        when Bignum
          [v, 'bigint']
        when Float
          [v, 'double precision']
        when Numeric
          [v, 'numeric']
        when Time
          if v.is_a?(SQLTime)
            [literal(v), 'time']
          else
            [literal(v), 'datetime']
          end
        when DateTime
          [literal(v), 'datetime']
        when Date
          [literal(v), 'date']
        when nil
          ['NULL', 'nvarchar(max)']
        when true
          ['1', 'int']
        when false
          ['0', 'int']
        when SQL::Blob
          [literal(v), 'varbinary(max)']
        else
          [literal(v), 'nvarchar(max)']
        end
      end
    end
    
    class Dataset < Sequel::Dataset
      include Sequel::MSSQL::DatasetMethods

      Database::DatasetClass = self
      
      # SQLite already supports named bind arguments, so use directly.
      module ArgumentMapper
        include Sequel::Dataset::ArgumentMapper
        
        protected
        
        # Return a hash with the same values as the given hash,
        # but with the keys converted to strings.
        def map_to_prepared_args(hash)
          args = {}
          hash.each{|k,v| args[k.to_s.gsub('.', '__')] = v}
          args
        end
        
        private
        
        # SQLite uses a : before the name of the argument for named
        # arguments.
        def prepared_arg(k)
          LiteralString.new("@#{k.to_s.gsub('.', '__')}")
        end

        # Always assume a prepared argument.
        def prepared_arg?(k)
          true
        end
      end
      
      # SQLite prepared statement uses a new prepared statement each time
      # it is called, but it does use the bind arguments.
      module PreparedStatementMethods
        include ArgumentMapper
        
        private
        
        # Run execute_select on the database with the given SQL and the stored
        # bind arguments.
        def execute(sql, opts={}, &block)
          super(prepared_sql, {:arguments=>bind_arguments}.merge(opts), &block)
        end
        
        # Same as execute, explicit due to intricacies of alias and super.
        def execute_dui(sql, opts={}, &block)
          super(prepared_sql, {:arguments=>bind_arguments}.merge(opts), &block)
        end
        
        # Same as execute, explicit due to intricacies of alias and super.
        def execute_insert(sql, opts={}, &block)
          super(prepared_sql, {:arguments=>bind_arguments}.merge(opts), &block)
        end
      end
      
      # Yield hashes with symbol keys, attempting to optimize for
      # various cases.
      def fetch_rows(sql)
        execute(sql) do |result|
          each_opts = {:cache_rows=>false}
          each_opts[:timezone] = :utc if db.timezone == :utc
          rn = row_number_column if offset = @opts[:offset]
          columns = cols = result.fields.map{|c| output_identifier(c)}
          if offset
            rn = row_number_column
            columns = columns.dup
            columns.delete(rn)
          end
          @columns = columns
          #if identifier_output_method
            each_opts[:as] = :array
            result.each(each_opts) do |r|
              h = {}
              cols.zip(r).each{|k, v| h[k] = v}
              h.delete(rn) if rn
              yield h
            end
=begin
        # Temporarily disable this optimization, as tiny_tds uses string keys
        # if result.fields is called before result.each(:symbolize_keys=>true).
        # See https://github.com/rails-sqlserver/tiny_tds/issues/57
          else
            each_opts[:symbolize_keys] = true
            if offset
              result.each(each_opts) do |r|
                r.delete(rn) if rn
                yield r
              end
            else
              result.each(each_opts, &Proc.new)
            end
          end
=end
        end
        self
      end
      
      # Create a named prepared statement that is stored in the
      # database (and connection) for reuse.
      def prepare(type, name=nil, *values)
        ps = to_prepared_statement(type, values)
        ps.extend(PreparedStatementMethods)
        if name
          ps.prepared_statement_name = name
          db.set_prepared_statement(name, ps)
        end
        ps
      end
      
      private
      
      # Properly escape the given string +v+.
      def literal_string_append(sql, v)
        sql << (mssql_unicode_strings ? UNICODE_STRING_START : APOS)
        sql << db.synchronize{|c| c.escape(v)}.gsub(BACKSLASH_CRLF_RE, BACKSLASH_CRLF_REPLACE) << APOS
      end
    end
  end
end
