#!/usr/bin/env ruby

require 'set'


class Arg < Struct.new(:name, :long, :short, :help, :default, :type, :choices, :proc, :required, :group)

    # name: destination name
    # long: long option.  "--" + dest.gsub("_", "-")
    # short: char(single length string) - for short options such as "-a"
    # default: default value -  can be anything
    # proc: Proc - check and convert the value Proc.new{ |f| File.exist?(f) }
    # type: Class - Integer / Float / String
    # choises: Array - to give the choises


    TYPES = [Integer, Float, String, Symbol]

    # optional
    def self.optional(name, help=nil, short=true, **hash)
        long = "--" + name.to_s.gsub("_", "-")          # long is required
        short = (short == true) ? long[1..2] : short
        self.new(name, long, short, help, **hash)
    end

    # positional
    def self.positional(name, help=nil, **hash)
        self.new(name, nil, nil, help, **hash)
    end

    def initialize(name, long, short, help, **hash)

        default = hash.delete(:default)
        type = hash.delete(:type)
        choices = hash.delete(:choices)
        proc = hash.delete(:proc)
        required = hash.delete(:required)

        raise ArgumentError, "unkown keys #{hash.keys}" unless hash.empty?
        raise ArgumentError, "type must be a #{TYPES}" unless TYPES.include?(type) if type
        raise ArgumentError, "choices must be given as an Array" unless choices.is_a?(Array) if choices
        raise ArgumentError, "empty choices are given" if choices.empty? if choices
        raise ArgumentError, "proc must be Proc (#{proc.class} is given)" unless proc.is_a?(Proc) if proc

        if type.nil?   # auto type
            if default
                type = TYPES.find{ |klass| default.is_a?(klass) }
            elsif choices
                type = TYPES.find{ |klass| choices.compact.all?{ |a| a.is_a?(klass) } }
            end
        end

        super(name, long, short, help, default, type, choices, proc, required)       # :group wiil be assigned later
    end

    def is_boolean?
        default == true or default == false
    end

    def cast(str)
        case self.type
            when Integer then Integer(str)
            when Float  then Float(str)
            when String then str
            when Symbol then str.to_sym
            else str
        end
    end

    def parse(args, i)
        if is_boolean?
            !self.default
        else
            value = args.delete_at(i)
            raise ArgumentError, "no value follows" if value.nil?

            # cast
            value = cast(value) if self.type

            # choices
            raise ArgumentError, "value #{value} is not in #{self.choices}" if choices.include?(value) if self.choices

            # proc
            value = self.proc.call(value) if self.proc

            return value
        end
    end

    def usage_array
        type_str = self.type ? "[#{self.type.inspect}]" : is_boolean? ? "[Flag]" : nil
        default_str = self.default ? "default=#{self.default.inspect}" : nil
        choices_str = self.choices ? "choice:#{choices}" : nil
        helpstr = [self.help, default_str, choices_str].compact.join(", ")
        metavar = (is_boolean? ? nil : self.name.to_s.upcase)
        [self.long, self.short, metavar, type_str, helpstr].map{ |s| s or "" }
    end
end



class ArgParser
    ACCEPTABLE_VALUES = [String, Numeric, Proc, Array, TrueClass, FalseClass]
    
    def initialize(ignore_unkown=false)
        help = Arg.optional(:help, "to show help", default:false)
        @optset = Set.new

        @longhash = Hash[help.long, help]
        @shorthash = Hash[help.short, help]
        @positional = Array.new

        @ignore_unkown = ignore_unkown
    end
    
    def add_opt(*args, group: :default)

        args.each.with_index{ |o,i|

            raise ArgumentError, "arg #{i} is not Arg (#{o.class} is given)" unless o.is_a?(Arg)

            o.group = group    # default group
            raise "opt name :help is reverved" if o.name == :help
            raise "opt name #{o.name.inspect} already taken" unless @optset.add?(o.name)

            if o.long
                raise "long option \"#{o.long}\" is already token by #{@longhash[o.long]}" if @longhash.has_key?(o.long)
                @longhash[o.long] = o
                if o.short
                    raise "short option \"#{o.short}\" is already token by #{@shorthash[o.short]}" if @shorthash.has_key?(o.short)
                    @shorthash[o.short] = o
                end
            else
                @positional.push(o)
            end
        }
    end
    
    def usage
        "    usage : #{$0} " + @positional.map{ |o| o.name.to_s.upcase }.join(" ")
    end
    
    def help

        output = Array.new
        output += [" positionals:", *@positional.map(&:usage_array)] unless @positional.empty?
        output += [" optionals:", *@longhash.values.map(&:usage_array)] unless @longhash.empty?

        # format
        format_len = output.select{ |o| o.is_a?(Array) }.transpose.map{ |ary| ary.map(&:length).max }
        output.map!{ |o| o.is_a?(Array) ? "    " + o.zip(format_len).map{ |s,i| s.ljust(i) }.join("    ") : o }.join("\n")
    end

    def abort(comment=nil)
        Kernel.abort "ArgParser Error : " + comment + "\n\n" + usage
    end
    
    def parse(argv)
        parsed = Hash.new
        positionals = @positional.clone

        i = 0
        pos = 0
        while a = argv[i]

            if a.start_with?("-")

                if opt = @longhash[a]       # if long option
                    argv.delete_at(i)

                elsif opt = @shorthash[a[0..2]]
                    if a.length == 2        # if short like "-h"
                        argv.delete_at(i)
                    elsif opt.is_boolean?
                        argv[i] = "-" + a[2..a.length]          # if "-hce"
                    else
                        argv[i] = a[2..a.length]                # if "-hvalue"
                    end
                elsif @ignore_unkown
                    i += 1
                    next
                else
                    abort "unkown option #{a}"
                end

            elsif opt = positionals.pop
                pos += 1
            else
                if ignore_unkown
                    i += 1
                    next
                else
                    abort "unkown positional #{a}" unless opt
                end
            end


            abort "option #{opt.name} parsed multiple times" if parsed.has_key?(opt.name)

            # print help
            Kernel.abort "\n#{usage}\n\n#{help}\n\n" if opt.name == :help

            # parse
            begin
                value = opt.parse(argv, i)
            rescue ArgumentError => error
                abort "  Error on parsing opt \"#{opt.long or opt.name}\": " + error.message
            end
            parsed[opt.name] = value
        end


        # unless all positional done
        abort "positional #{positionals.map(&:name).map(&:upcase).join(", ")} required" unless positionals.empty?

        # build output
        output = Hash.new{ |hash, key| hash[key] = Hash.new }
        (@longhash.values + @positional).each{ |opt|
            next unless opt.group
            output[opt.group][opt.name] = (parsed[opt.name] or opt.default)
        }
        output.default_proc = nil

        return output
    end
    

end


if __FILE__ == $0

    parser = ArgParser.new
    parser.add_opt(Arg.optional(:test, "this is test", default:10))
    parser.add_opt(Arg.positional(:hogehoge, "this is test", default:"30.0"))
    puts parser.usage
    puts parser.help
    p parser.parse(ARGV)

    
    
end
