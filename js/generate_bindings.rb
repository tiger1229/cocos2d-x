#/usr/bin/env ruby
# script to generate bindings using the cocos2d.xml generated by clang
# in order to get the C++ info

require 'rubygems'
require 'nokogiri'

class String
  def uncapitalize
    self[0].downcase + self[1, length]
  end
  def capitalize
    self[0].upcase + self[1, length]
  end
end

class CppMethod
  attr_reader :name, :static, :num_arguments

  def initialize(node, klass, bindings_generator)
    @name = node['name']
    @static = node['static'] == "1" ? true : false
    @num_arguments = node['num_args'].to_i
  end

  def generate_method_code
  end

  def generate_setter_code
  end

  def generate_getter_code
  end
end

class CppClass
  attr_reader :name

  # initialize the class with a nokogiri node
  def initialize(node, bindings_generator)
    @generator = bindings_generator
    @parents = []
    @properties = {}
    @methods = {}
    # the constructor/init methods
    @constructors = []
    @init_methods = []

    @name = node['name']
    # puts node if @name == "CCPoint"

    # test for super classes
    (node / "Base").each do |base|
      klass = bindings_generator.classes[base['id']]
      @parents << klass
    end

    (node / "Field").each do |field|
      # puts field if @name == "CCPoint"
      md = field['name'].match(/m_([nfpbt])(\w+)/)
      if md
        field_name = md[2].uncapitalize
        @properties[field_name] = {:type => field['type'], :getter => nil, :setter => nil}
      else
        @properties[field['name']] = {:type => field['type']} if field['access'] == 'public'
      end
    end

    (node / "CXXConstructor").each do |method|
      @constructors << CppMethod.new(method, self, bindings_generator)
    end

    (node / "CXXMethod").each do |method|
      # the accessors
      if md = method['name'].match(/(get|set)(\w+)/)
        action = md[1]
        field_name = md[2].uncapitalize
        prop = @properties[field_name]
        if prop
          prop[:getter] = CppMethod.new(method, self, bindings_generator) if action == "get"
          prop[:setter] = CppMethod.new(method, self, bindings_generator) if action == "set"
        end
      # store the initXXX methods
      # elsif md = method['name'].match(/^init/)
      #   @init_methods << CppMethod.new(method, self, bindings_generator)
      # everything else but operator overloading
      elsif method['name'] !~ /^operator/
        if method['access'] == "public"
          m = CppMethod.new(method, self, bindings_generator)
          @methods[m.name] ||= []
          @methods[m.name] << m
        end
      end # if (accessor)
    end
  end

  def generate_properties_enum
    arr = []
    @properties.each_with_index do |prop, i|
      name = prop[0]
      arr << "\t\tk#{name.capitalize}" + (i == 0 ? " = 1" : "")
    end
    str =  "\tenum {\n"
    str << arr.join(",\n") << "\n"
    str << "\t};\n"
  end

  def generate_properties_array
    arr = []
    @properties.each do |prop|
      name = prop[0]
      arr << "\t\t\t{\"#{name}\", k#{name.capitalize}, JSPROP_PERMANENT | JSPROP_SHARED, S_#{@name}::jsPropertyGet, S_#{@name}::jsPropertySet}"
    end
    arr << "\t\t\t{0, 0, 0, 0, 0}"
    str =  "\t\tstatic JSPropertySpec properties[] = {\n"
    str << arr.join(",\n") << "\n"
    str << "\t\t};\n"
  end

  def generate_funcs_array
    arr = []
    @methods.each do |method|
      name = method[0]
      m = method[1].first
      arr << "\t\t\tJS_FN(\"#{name}\", S_#{@name}::#{name}, #{m.num_arguments}, JSPROP_PERMANENT | JSPROP_SHARED)"
    end
    arr << "\t\t\tJS_FS_END"
    str =  "\t\tstatic JSFunctionSpec funcs[] = {\n"
    str << arr.join(",\n") << "\n"
    str << "\t\t};\n"
  end

  def generate_funcs
    str = ""
    @methods.each do |method|
      name = method[0]
      m = method[1].first
      str << "\tJSBool #{name}(JSContext *cx, uint32_t argc, jsval *vp) {\n"
      str << "\t\tJS_SET_RVAL(cx, vp, JSVAL_TRUE);"
      str << "\t\treturn JS_TRUE;\n"
      str << "\t};"
    end
  end

  def generate_constructor_code
    str =  ""
    str << "\tS_#{@name}(JSObject *obj) : #{@name}(), m_obj(obj) {};\n\n"
    str << "\tstatic JSBool jsConstructor(JSContext *cx, uint32_t argc, jsval *vp)\n"
    str << "\t{\n"
    str << "\t\tJSObject *obj = JS_NewObject(cx, S_#{@name}::jsClass, S_#{@name}::jsObject, NULL);\n"
    str << "\t\tS_#{@name} *cobj = new S_#{@name}(obj);\n"
    str << "\t\tpointerShell_t *pt = (pointerShell_t *)JS_malloc(cx, sizeof(pointerShell_t));\n"
    str << "\t\tpt->flags = 0; pt->data = cobj;"
    str << "\t\tJS_SetPrivate(obj, pt);\n"
    str << "\t\tJS_SET_RVAL(cx, vp, OBJECT_TO_JSVAL(obj));\n"
    str << "\t\treturn JS_TRUE;\n"
    str << "\t};\n"
  end

  def generate_finalizer
    str =  ""
    str << "\tstatic void jsFinalize(JSContext *cx, JSObject *obj)\n"
    str << "\t{\n"
    str << "\t\tpointerShell_t *pt = (pointerShell_t *)JS_GetPrivate(obj);\n"
    str << "\t\tif (pt) {\n"
    str << "\t\t\tif (!(pt->flags & kPointerTemporary) && pt->data) delete (S_#{@name} *)pt->data;\n"
    str << "\t\t\tJS_free(cx, pt);\n"
    str << "\t\t}\n"
    str << "\t};\n"
  end

  def generate_getter
    str =  ""
    str << "\tstatic JSBool jsPropertyGet(JSContext *cx, JSObject *obj, jsid _id, jsval *val)\n"
    str << "\t{\n"
    str << "\t\tint32_t propId = JSID_TO_INT(_id);\n"
    str << "\t\tS_#{@name} *cobj; JSGET_PTRSHELL(S_#{@name}, cobj, obj);\n"
    str << "\t\tif (!cobj) return JS_FALSE;\n"
    str << "\t\tswitch(propId) {\n"
    @properties.each do |prop, val|
      str << "\t\tcase k#{prop.capitalize}:\n"
      str << "\t\t\t#{convert_value_to_js(val, "cobj->#{prop}", "val", 3)}\n"
      str << "\t\t\treturn JS_TRUE;\n"
      str << "\t\t\tbreak;\n"
    end
    str << "\t\tdefault:\n"
    str << "\t\t\tbreak;\n"
    str << "\t\t}\n"
    str << "\t\treturn JS_FALSE;\n"
    str << "\t};\n"
  end

  def generate_setter
    str =  ""
    str << "\tstatic JSBool jsPropertySet(JSContext *cx, JSObject *obj, jsid _id, JSBool strict, jsval *val)\n"
    str << "\t{\n"
    str << "\t\tint32_t propId = JSID_TO_INT(_id);\n"
    str << "\t\tS_#{@name} *cobj; JSGET_PTRSHELL(S_#{@name}, cobj, obj);\n"
    str << "\t\tif (!cobj) return JS_FALSE;\n"
    str << "\t\tJSBool ret = JS_FALSE;\n"
    str << "\t\tswitch(propId) {\n"
    @properties.each do |prop, val|
      str << "\t\tcase k#{prop.capitalize}:\n"
      str << "\t\t\t#{convert_value_from_js(val, "val", "cobj->#{prop}", 3)}\n"
      str << "\t\t\tret = JS_TRUE;\n"
      str << "\t\t\tbreak;\n"
    end
    str << "\t\tdefault:\n"
    str << "\t\t\tbreak;\n"
    str << "\t\t}\n"
    str << "\t\treturn ret;\n"
    str << "\t};\n"
  end

  def generate_code
    str =  ""
    str << "class S_#{@name} : public #{@name}\n"
    str << "{\n"
    str << "\tJSObject *m_obj;\n"
    str << "public:\n"
    str << "\tstatic JSClass *jsClass;\n"
    str << "\tstatic JSObject *jsObject;\n\n"
    str << generate_properties_enum << "\n"
    str << generate_constructor_code << "\n"
    str << generate_finalizer << "\n"
    str << generate_getter << "\n"
    str << generate_setter << "\n"
    # class registration method
    str << "\tstatic void jsCreateClass(JSContext *cx, JSObject *globalObj, const char *name)\n"
    str << "\t{\n"
    str << "\t\tjsClass = (JSClass *)calloc(1, sizeof(JSClass));\n"
    str << "\t\tjsClass->name = name;\n"
    str << "\t\tjsClass->addProperty = JS_PropertyStub;\n"
    str << "\t\tjsClass->delProperty = JS_PropertyStub;\n"
    str << "\t\tjsClass->getProperty = JS_PropertyStub;\n"
    str << "\t\tjsClass->setProperty = JS_StrictPropertyStub;\n"
    str << "\t\tjsClass->enumerate = JS_EnumerateStub;\n"
    str << "\t\tjsClass->resolve = JS_ResolveStub;\n"
    str << "\t\tjsClass->convert = JS_ConvertStub;\n"
    str << "\t\tjsClass->finalize = jsFinalize;\n"
    str << "\t\tjsClass->flags = JSCLASS_HAS_PRIVATE;\n"
    str << generate_properties_array << "\n"
    str << generate_funcs_array << "\n"
    str << "\t\tjsObject = JS_InitClass(cx,globalObj,NULL,jsClass,S_#{@name}::jsConstructor,0,properties,funcs,NULL,NULL);\n"
    str << "\t};\n"
    str << "};\n\n"
    str << generate_funcs << "\n"
    str << "JSClass* S_#{@name}::jsClass = NULL;\n"
    str << "JSObject* S_#{@name}::jsObject = NULL;\n"
  end

  def to_s
    generate_code
  end

private
  # convert a JS object to C++
  def convert_value_from_js(val, invalue, outvalue, indent_level)
    prop = val[:type]
    indent = "\t" * (indent_level || 0)
    str = ""
    type = @generator.fundamental_types[prop]
    if type
      case type
      when /int|long|float|double|short/
        str << "do { double tmp; JS_ValueToNumber(cx, *#{invalue}, &tmp); #{outvalue} = tmp; } while (0);"
      end
    else
      type = @generator.pointer_types[prop]
      ref = false
      if type.nil?
        type = @generator.classes[prop]
        ref = true
      end
      if type
        str << "do {\n"
        str << "#{indent}\t#{type[:name]}* tmp; JSGET_PTRSHELL(#{type[:name]}, tmp, JSVAL_TO_OBJECT(*#{invalue}));\n"
        str << "#{indent}\tif (tmp) { #{outvalue} = #{ref ? "*" : ""}tmp; }\n"
        str << "#{indent}} while (0);"
      else
        str << "// don't know what this is"
      end
    end
    str
  end

  # convert a C++ object to JS
  def convert_value_to_js(val, invalue, outvalue, indent_level)
    prop = val[:type]
    indent = "\t" * (indent_level || 0)
    str = ""
    type = @generator.fundamental_types[prop]
    if type
      # ok, it's a fundamental type... so let's convert that to proper js type
      case type
      when /int|long|float|double|short/
        str << "JS_NewNumberValue(cx, #{val[:getter] ? "cobj->#{val[:getter].name}()" : invalue}, #{outvalue});"
      end
    else
      type = @generator.pointer_types[prop]
      ref = false
      if type.nil?
        type = @generator.classes[prop]
        ref = true
      end
      if type
        is_class = type[:kind] == :class
        js_class = (is_class) ? "S_#{type[:name]}::jsClass" : "NULL"
        js_proto = (is_class) ? "S_#{type[:name]}::jsObject" : "NULL"
        str << "do {\n"
        str << "#{indent}\tJSObject *tmp = JS_NewObject(cx, #{js_class}, #{js_proto}, NULL);\n"
        str << "#{indent}\tpointerShell_t *pt = (pointerShell_t *)JS_malloc(cx, sizeof(pointerShell_t));\n"
        str << "#{indent}\tpt->flags = kPointerTemporary;\n"
        str << "#{indent}\tpt->data = #{ref ? "&" : ""}#{invalue};\n"
        str << "#{indent}\tJS_SetPrivate(tmp, pt);\n"
        str << "#{indent}\tJS_SET_RVAL(cx, #{outvalue}, OBJECT_TO_JSVAL(tmp));\n"
        str << "#{indent}} while (0);"
      else
        str << "// don't know what this is"
      end # if type
    end # if type
    str
  end
end

class BindingsGenerator
  attr_reader :classes, :fundamental_types, :pointer_types

  # initialize everything with a nokogiri document
  def initialize(doc)
    raise "Invalid XML file" if doc.root.name != "CLANG_XML"
    @translation_unit = (doc.root / "TranslationUnit").first rescue nil
    test_xml(@translation_unit && @translation_unit.name == "TranslationUnit")

    @reference_section = (doc.root / "ReferenceSection").first rescue nil
    test_xml(@reference_section && @reference_section.name == "ReferenceSection")

    @fundamental_types = {}
    @pointer_types = {}
    @classes = {}

    find_fundamental_types
    find_pointer_types
    find_classes
end

private
  def test_xml(cond)
    raise "invalid XML file" if !cond
  end

  def find_fundamental_types
    (@reference_section / "FundamentalType").each do |ft|
      @fundamental_types[ft['id']] = ft['kind']
    end
  end

  def find_pointer_types
    (@reference_section / "PointerType").each do |pt|
      ft = @fundamental_types[pt['type']]
      if ft
        @pointer_types[pt['id']] = {:type => pt['type'], :name => ft, :kind => :fundamental}
      else
        # will be filled later
        @pointer_types[pt['id']] = {:type => pt['type'], :kind => :class}
      end
    end
  end

  def find_classes
    (@reference_section / "Record[@kind=class]").each do |record|
      # find the pointer type and fill in the info
      pt = @pointer_types.select { |k,v| v[:type] == record['id'] }.first
      if pt
        pt[1][:name] = record['name']
      end # if pointer type
      # find the record on the translation unit and create the class
      (@translation_unit / "*/CXXRecord[@type=#{record['id']}]").each do |cxx_record|
        if cxx_record['forward'].nil?
          # just store the xml, we will instantiate them later
          @classes[record['id']] = {:name => record['name'], :kind => :class, :xml => cxx_record}
          break
        end
      end # each CXXRecord
    end # each Record(class)
    # p @pointer_types
    # actually create the generators
    # p @classes.map { |k,v| v[:name] }
    @classes.select { |k,v| %w(CCPoint CCSize CCRect CCNode).include?(v[:name]) }.each do |k,v|
      v[:generator] = CppClass.new(v[:xml], self)
      puts v[:generator]
    end
  end
end

doc = Nokogiri::XML(File.read("cocos2d.xml"))
BindingsGenerator.new(doc)

# (tu / "*/CXXRecord").each do |record|
#   pt = pointer_types[record['type']]
#   if pt && pt[:kind] == :class && record['forward'].nil?
#     puts "class: #{record['name']}"
#   end
# end

# puts fundamental_types.inspect
# puts pointer_types.inspect
