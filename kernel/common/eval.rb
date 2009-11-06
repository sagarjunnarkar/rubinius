module Kernel

  # Names of local variables at point of call (including evaled)
  #
  def local_variables
    locals = []

    scope = Rubinius::VariableScope.of_sender

    # Ascend up through all applicable blocks to get all vars.
    while scope
      if scope.method.local_names
        scope.method.local_names.each do |name|
          name = name.to_s
          locals << name unless name =~ /\A(@{1,2}|\$)/   # @todo Weed out "constants"? --rue
        end
      end

      # Should not have any special cases here
      if dyn = scope.dynamic_locals
        dyn.keys.each {|name| locals << name.to_s }
      end

      scope = scope.parent
    end

    locals
  end
  module_function :local_variables

  # Obtain binding here for future evaluation/execution context.
  #
  def binding()
    return Binding.setup(
      Rubinius::VariableScope.of_sender,
      Rubinius::CompiledMethod.of_sender,
      Rubinius::StaticScope.of_sender)
  end
  module_function :binding

  # Evaluate and execute code given in the String.
  #
  def eval(string, binding=nil, filename=nil, lineno=1)
    filename ||= binding ? binding.static_scope.active_path : "(eval)"

    # shortcut for checking for a local in a binding!
    # This speeds rails up quite a bit because it uses this in rendering
    # a view A LOT.
    #
    # TODO eval the AST rather than compiling. Thats slightly slower than
    # this, but handles infinitely more cases.
    if binding
      if m = /^\s*defined\? ([a-z][A-Za-z0-9_]?)+\s*$/.match(string)
        local = m[1].to_sym
        if binding.variables.local_defined?(local)
          return "local-variable"
        else
          return nil
        end
      end
    end

    if !binding
      binding = Binding.setup(Rubinius::VariableScope.of_sender,
                              Rubinius::CompiledMethod.of_sender,
                              Rubinius::StaticScope.of_sender)

      # TODO why using __kind_of__ here?
    elsif binding.__kind_of__ Proc
      binding = binding.binding
    elsif !binding.__kind_of__ Binding
      raise ArgumentError, "unknown type of binding"
    end

    context = Rubinius::CompilerNG::Context.new binding.variables, binding.code

    compiled_method = Rubinius::CompilerNG.compile_eval string, context, filename, lineno
    compiled_method.scope = binding.static_scope
    compiled_method.name = :__eval__

    yield compiled_method if block_given?

    # This has to be setup so __FILE__ works in eval.
    script = Rubinius::CompiledMethod::Script.new
    script.path = filename
    compiled_method.scope.script = script
    script.path = binding.static_scope.active_path if binding

    # Internalize it now, since we're going to springboard to it as a block.
    compiled_method.compile

    be = Rubinius::BlockEnvironment.new
    be.under_context binding.variables, compiled_method

    # Pass the BlockEnvironment this binding was created from
    # down into the new BlockEnvironment we just created.
    # This indicates the "declaration trace" to the stack trace
    # mechanisms, which can be different from the "call trace"
    # in the case of, say: eval("caller", a_proc_instance)
    if binding.from_proc?
      be.proc_environment = binding.proc_environment
    end

    be.from_eval!
    be.call
  end
  module_function :eval
  private :eval

  ##
  # :call-seq:
  #   obj.instance_eval(string [, filename [, lineno]] )   => obj
  #   obj.instance_eval {| | block }                       => obj
  #
  # Evaluates a string containing Ruby source code, or the given block, within
  # the context of the receiver +obj+. In order to set the context, the
  # variable +self+ is set to +obj+ while the code is executing, giving the
  # code access to +obj+'s instance variables. In the version of
  # #instance_eval that takes a +String+, the optional second and third
  # parameters supply a filename and starting line number that are used when
  # reporting compilation errors.
  #
  #   class Klass
  #     def initialize
  #       @secret = 99
  #     end
  #   end
  #   k = Klass.new
  #   k.instance_eval { @secret }   #=> 99

  def instance_eval(string=nil, filename="(eval)", line=1, &prc)
    if prc
      if string
        raise ArgumentError, 'cannot pass both a block and a string to evaluate'
      end
      # Return a copy of the BlockEnvironment with the receiver set to self
      env = prc.block
      static_scope = env.method.scope.using_current_as(__metaclass__)
      return env.call_under(self, static_scope, self)
    elsif string
      string = StringValue(string)

      # TODO refactor this common code with #eval
      binding = Binding.setup(Rubinius::VariableScope.of_sender,
                              Rubinius::CompiledMethod.of_sender,
                              Rubinius::StaticScope.of_sender)

      context = Rubinius::CompilerNG::Context.new binding.variables, binding.code

      compiled_method = Rubinius::CompilerNG.compile_eval string, context, filename, line
      compiled_method.scope = binding.static_scope.using_current_as(metaclass)
      compiled_method.name = :__instance_eval__
      compiled_method.compile

      # This has to be setup so __FILE__ works in eval.
      script = Rubinius::CompiledMethod::Script.new
      script.path = filename
      compiled_method.scope.script = script

      be = Rubinius::BlockEnvironment.new
      be.from_eval!
      be.under_context binding.variables, compiled_method
      be.call_on_instance(self)
    else
      raise ArgumentError, 'block not supplied'
    end
  end

  ##
  # :call-seq:
  #   obj.instance_exec(arg, ...) { |var,...| block }  => obj
  #
  # Executes the given block within the context of the receiver +obj+. In
  # order to set the context, the variable +self+ is set to +obj+ while the
  # code is executing, giving the code access to +obj+'s instance variables.
  #
  # Arguments are passed as block parameters.
  #
  #   class Klass
  #     def initialize
  #       @secret = 99
  #     end
  #   end
  #
  #   k = Klass.new
  #   k.instance_exec(5) {|x| @secret+x }   #=> 104

  def instance_exec(*args, &prc)
    raise ArgumentError, "Missing block" unless block_given?
    env = prc.block
    static_scope = Rubinius::StaticScope.of_sender.using_current_as(__metaclass__)
    return env.call_under(self, static_scope, *args)
  end
end

class Module

  #--
  # These have to be aliases, not methods that call instance eval, because we
  # need to pull in the binding of the person that calls them, not the
  # intermediate binding.
  #++

  def module_eval(string=Undefined, filename="(eval)", line=1, &prc)
    # we have a custom version with the prc, rather than using instance_exec
    # so that we can setup the StaticScope properly.
    if prc
      unless string.equal?(Undefined)
        raise ArgumentError, "cannot pass both string and proc"
      end

      # Return a copy of the BlockEnvironment with the receiver set to self
      env = prc.block
      static_scope = env.method.scope.using_current_as(self)
      return env.call_under(self, static_scope, self)
    elsif string.equal?(Undefined)
      raise ArgumentError, 'block not supplied'
    end

    # TODO refactor this common code with #eval

    variables = Rubinius::VariableScope.of_sender
    method = Rubinius::CompiledMethod.of_sender

    context = Rubinius::CompilerNG::Context.new variables, method

    string = StringValue(string)

    compiled_method = Rubinius::CompilerNG.compile_eval string, context, filename, line

    # The staticscope of a module_eval CM is the receiver of module_eval
    ss = Rubinius::StaticScope.new self, Rubinius::StaticScope.of_sender

    # This has to be setup so __FILE__ works in eval.
    script = Rubinius::CompiledMethod::Script.new
    script.path = filename
    ss.script = script

    compiled_method.scope = ss
    compiled_method.compile

    # The gist of this code is that we need the receiver's static scope
    # but the caller's binding to implement the proper constant behavior
    be = Rubinius::BlockEnvironment.new
    be.from_eval!
    be.under_context variables, compiled_method
    be.call_under self, ss, self
  end

  alias_method :class_eval, :module_eval
end
