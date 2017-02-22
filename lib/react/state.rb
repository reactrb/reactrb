module React
  class StateWrapper < BasicObject
    def initialize(native, from)
      @state_hash = Hash.new(`#{native}.state`)
      @from = from
    end

    def [](state)
      @state_hash[state]
    end

    def []=(state, new_value)
      @state_hash[state] = new_value
    end

    def method_missing(method, *args)
      if match = method.match(/^(.+)\!$/)
        key_name = $1
        if args.count > 0
          current_value = State.get_state(@from, match[1])
          State.set_state(@from, key_name, args[0])
          current_value
        else
          current_state = State.get_state(@from, match[1])
          State.set_state(@from, key_name, current_state)
          Observable.new(current_state) do |update|
            State.set_state(@from, key_name, update)
          end
        end
      else
        State.get_state(@from, method)
      end
    end
  end

  class State

    @rendering_level = 0

    class << self
      attr_reader :current_observer

      def has_observers?(object, name)
        !observers_by_name[object][name].empty?
      end

      def bulk_update
        saved_bulk_update_flag = @bulk_update_flag
        @bulk_update_flag = true
        yield
      ensure
        @bulk_update_flag = saved_bulk_update_flag
      end

      def set_state2(object, name, value, updates, exclusions = nil)
        # set object's name state to value, tell all observers it has changed.
        # Observers must implement update_react_js_state
        object_needs_notification = object.respond_to? :update_react_js_state
        observers_by_name[object][name].dup.each do |observer|
          next if exclusions && exclusions.include?(observer)
          updates[observer] += [object, name, value]
          object_needs_notification = false if object == observer
        end
        updates[object] += [nil, name, value] if object_needs_notification
      end

      def initialize_states(object, initial_values) # initialize objects' name/value pairs
        states[object].merge!(initial_values || {})
      end

      def get_state(object, name, current_observer = @current_observer)
        # get current value of name for object, remember that the current object depends on this state,
        # current observer can be overriden with last param
        if current_observer && !new_observers[current_observer][object].include?(name)
          new_observers[current_observer][object] << name
        end
        if @delayed_updates && @delayed_updates[object][name]
          @delayed_updates[object][name][1] << current_observer
        end
        states[object][name]
      end

      def set_state(object, name, value, delay = true)
        states[object][name] = value

        # Only delay updates if we are NOT prerendering
        if IsomorphicHelpers.on_opal_client? && (delay || @bulk_update_flag)
          @delayed_updates ||= Hash.new { |h, k| h[k] = {} }
          @delayed_updates[object][name] = [value, Set.new]
          @delayed_updater ||= after(0.001) do
            delayed_updates = @delayed_updates
            @delayed_updates = Hash.new { |h, k| h[k] = {} } # could this be nil???
            @delayed_updater = nil
            updates = Hash.new { |hash, key| hash[key] = Array.new }
            delayed_updates.each do |object, name_hash|
              name_hash.each do |name, value_and_set|
                set_state2(object, name, value_and_set[0], updates, value_and_set[1])
              end
            end
            updates.each { |observer, args| observer.update_react_js_state(*args) }
          end
        elsif @rendering_level == 0
          updates = Hash.new { |hash, key| hash[key] = Array.new }
          set_state2(object, name, value, updates)
          updates.each { |observer, args| observer.update_react_js_state(*args) }
        end
        value
      end

      def notify_observers(object, name, value)
        object_needs_notification = object.respond_to? :update_react_js_state
        observers_by_name[object][name].dup.each do |observer|
          observer.update_react_js_state(object, name, value)
          object_needs_notification = false if object == observer
        end
        object.update_react_js_state(nil, name, value) if object_needs_notification
      end

      def notify_observers_after_thread_completes(object, name, value)
        (@delayed_updates ||= []) << [object, name, value]
        @delayed_updater ||= after(0) do
          delayed_updates = @delayed_updates
          @delayed_updates = []
          @delayed_updater = nil
          delayed_updates.each { |args| notify_observers(*args) }
        end
      end

      def will_be_observing?(object, name, current_observer)
        current_observer && new_observers[current_observer][object].include?(name)
      end

      def is_observing?(object, name, current_observer)
        current_observer && observers_by_name[object][name].include?(current_observer)
      end

      def update_states_to_observe(current_observer = @current_observer)  # should be called after the last after_render callback, currently called after components render method
        raise "update_states_to_observer called outside of watch block" unless current_observer
        current_observers[current_observer].each do |object, names|
          names.each do |name|
            observers_by_name[object][name].delete(current_observer)
          end
        end
        observers = current_observers[current_observer] = new_observers[current_observer]
        new_observers.delete(current_observer)
        observers.each do |object, names|
          names.each do |name|
            observers_by_name[object][name] << current_observer
          end
        end
      end

      def remove # call after component is unmounted
        raise "remove called outside of watch block" unless @current_observer
        current_observers[@current_observer].each do |object, names|
          names.each do |name|
            observers_by_name[object][name].delete(@current_observer)
          end
        end
        current_observers.delete(@current_observer)
      end

      def set_state_context_to(observer, rendering = nil) # wrap all execution that may set or get states in a block so we know which observer is executing
        if `typeof Opal.global.reactive_ruby_timing !== 'undefined'`
          @nesting_level = (@nesting_level || 0) + 1
          start_time = Time.now.to_f
          observer_name = (observer.class.respond_to?(:name) ? observer.class.name : observer.to_s) rescue "object:#{observer.object_id}"
        end
        saved_current_observer = @current_observer
        @current_observer = observer
        @rendering_level += 1 if rendering
        return_value = yield
        return_value
      ensure
        @current_observer = saved_current_observer
        @rendering_level -= 1 if rendering
        @nesting_level = [0, @nesting_level - 1].max if `typeof Opal.global.reactive_ruby_timing !== 'undefined'`
        return_value
      end

      def states
        @states ||= Hash.new { |h, k| h[k] = {} }
      end

      [:new_observers, :current_observers, :observers_by_name].each do |method_name|
        define_method(method_name) do
          instance_variable_get("@#{method_name}") ||
          instance_variable_set("@#{method_name}", Hash.new { |h, k| h[k] = Hash.new { |h, k| h[k] = [] } })
        end
      end
    end
  end
end
