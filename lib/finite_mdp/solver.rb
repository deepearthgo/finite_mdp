require 'narray'

#
# Find optimal values and policies using policy iteration and/or value
# iteration.
#
# These currently just iterate the Bellman equations; solving the linear system
# for policy evaluation is not yet supported.
#
# Only deterministic policies are supported.
#
# The solver converts the given model into a reasonably efficient internal
# representation before solving.
#
class FiniteMDP::Solver
  #
  # @param [Model] model
  #
  # @param [Float] discount in (0, 1]
  #
  # @param [Hash<state, action>] policy initial policy; if empty, an arbitrary
  #        action is selected for each state
  #
  # @param [Hash<state, Float>] value initial value for each state; defaults to
  #        zero for every state
  #
  def initialize model, discount, policy={}, value=Hash.new(0)
    @model = model

    # get the model data into a more compact form for calculation; this means
    # that we number the states and actions for faster lookups (avoid most of
    # the hashing); the 'next states' map is still stored in sparse format
    # (that is, as a hash)
    model_states = model.states
    state_to_num = Hash[model_states.zip(0...model_states.size)]
    @compacted_model = model_states.map {|state|
      model.actions(state).map {|action|
        Hash[model.next_states(state, action).map {|next_state|
          pr = model.transition_probability(state, action, next_state)
          [state_to_num[next_state], [pr, 
            model.reward(state, action, next_state)]] if pr > 0
        }.compact]
      }
    }

    @discount = discount
    @compacted_value    = model_states.map {|state| value[state]}
    if policy.empty?
      # default to the first action, arbitrarily
      @compacted_policy = [0]*model_states.size
    else
      # also must convert the initial policy and initial value into compact
      # form; to do this, we build a map from actions to action numbers; actions
      # are numbered per state, so we get one map per state
      action_to_num = model_states.map{|state|
        actions = model.actions(state)
        Hash[actions.zip(0...actions.size)]
      }
      @compacted_policy = action_to_num.zip(model_states).
                            map {|a_to_n, state| a_to_n[policy[state]]}
    end

    raise 'some initial values are missing' if
      @compacted_value.any? {|v| v.nil?}
    raise 'some initial policy actions are missing' if
      @compacted_policy.any? {|a| a.nil?}

    @policy_A = nil
  end

  #
  # @return [Model] the model being solved; read only; do not change the model
  # while it is being solved
  #
  attr_reader :model

  # 
  # Current value estimate for each state.
  #
  # The result is converted from the solver's internal representation, so you
  # cannot affect the solver by changing the result. 
  #
  # @return [Hash<state, Float>] from states to values; read only; any changes
  # made to the returned object will not affect the solver
  #
  def value
    Hash[model.states.zip(@compacted_value)]
  end

  #
  # Current estimate of the optimal action for each state.
  #
  # @return [Hash<state, action>] from states to actions; read only; any changes
  # made to the returned object will not affect the solver
  #
  def policy
    Hash[model.states.zip(@compacted_policy).map{|state, action_n|
      [state, model.actions(state)[action_n]]}]
  end

  #
  # Refine our estimate of the value function for the current policy; this can
  # be used to implement variants of policy iteration.
  #
  # This is the 'policy evaluation' step in Figure 4.3 of Sutton and Barto
  # (1998).
  #
  # @return [Float] largest absolute change (over all states) in the value
  # function
  #
  def evaluate_policy
    delta = 0.0
    @compacted_model.each_with_index do |actions, state_n|
      next_state_ns = actions[@compacted_policy[state_n]]
      new_value = backup(next_state_ns)
      delta = [delta, (@compacted_value[state_n] - new_value).abs].max
      @compacted_value[state_n] = new_value
    end
    delta
  end

  def evaluate_policy_exact
    if @policy_A
      # update only those rows that have changed
      @policy_A_action.zip(@compacted_policy).
        each_with_index do |(old_action_n, new_action_n), state_n|
        next if old_action_n == new_action_n
        puts "updating #{state_n}"
        update_policy_Ab state_n, new_action_n
      end
    else
      # initialise the A and the b for Ax = b
      @policy_A = NMatrix.float(num_states, num_states)
      @policy_A_action = [-1]*num_states
      @policy_b = NVector.float(num_states)

      @compacted_policy.each_with_index do |action_n, state_n|
        update_policy_Ab state_n, action_n
      end
    end

    value = @policy_b / @policy_A # solve linear system
    @compacted_value = value.to_a
    nil
  end

  def num_states
    @compacted_model.size
  end

  def update_policy_Ab state_n, action_n
    # clear out the old values for state_n's row
    @policy_A[true, state_n] = 0.0

    # set new values according to state_n's successors under the current policy
    b_n = 0
    next_state_ns = @compacted_model[state_n][action_n]
    next_state_ns.each do |next_state_n, (probability, reward)|
      @policy_A[next_state_n, state_n] = -@discount*probability
      b_n += probability*reward
    end
    @policy_A[state_n, state_n] += 1
    @policy_A_action[state_n] = action_n
    @policy_b[state_n] = b_n
  end

  #
  # Make our policy greedy with respect to our current value function; this can
  # be used to implement variants of policy iteration.
  #
  # This is the 'policy improvement' step in Figure 4.3 of Sutton and Barto
  # (1998).
  # 
  # @return [Boolean] false iff the policy changed for any state
  #
  def improve_policy
    stable = true
    @compacted_model.each_with_index do |actions, state_n|
      a_max = nil
      v_max = -Float::MAX
      actions.each_with_index do |next_state_ns, action_n|
        v = backup(next_state_ns)
        if v > v_max
          a_max = action_n
          v_max = v
        end
      end
      raise "no feasible actions in state #{state_n}" unless a_max
      stable = false if @compacted_policy[state_n] != a_max
      @compacted_policy[state_n] = a_max
    end
    stable
  end

  #
  # Do one iteration of value iteration.
  #
  # This is the algorithm from Figure 4.5 of Sutton and Barto (1998). It is
  # mostly equivalent to calling evaluate_policy and then improve_policy, but it
  # does fewer backups.
  #
  # @return [Float] largest absolute change (over all states) in the value
  # function
  #
  def one_value_iteration
    delta = 0.0
    @compacted_model.each_with_index do |actions, state_n|
      a_max = nil
      v_max = -Float::MAX
      actions.each_with_index do |next_state_ns, action_n|
        v = backup(next_state_ns)
        if v > v_max
          a_max = action_n
          v_max = v
        end
      end
      delta = [delta, (@compacted_value[state_n] - v_max).abs].max
      @compacted_value[state_n] = v_max
      @compacted_policy[state_n] = a_max
    end
    delta
  end

  private

  def backup next_state_ns
    next_state_ns.map {|next_state_n, (probability, reward)|
      probability*(reward + @discount*@compacted_value[next_state_n])
    }.inject(:+)
  end
end

#class FiniteMDP::DenseSolver
#  #
#  # @param [Model] model
#  #
#  # @param [Float] discount in (0, 1]
#  #
#  # @param [Hash<state, action>] policy initial policy; if empty, an arbitrary
#  #        action is selected for each state
#  #
#  # @param [Hash<state, Float>] value initial value for each state; defaults to
#  #        zero for every state
#  #
#  def initialize model, discount, policy={}, value=Hash.new(0)
#    @model = model
#
#    # build the 
#    model_states = model.states
#    n = model_states.size
#    state_to_num = Hash[model_states.zip(0...n)]
#    @compacted_model = model_states.map {|state|
#      model.actions(state).map {|action|
#        row = NVector.float(n)
#        model.next_states(state, action).each do |next_state|
#          row[state_to_num[next_state]] =
#            model.transition_probability(state, action, next_state) *
#            model.reward(state, action, next_state)
#        end
#        row *= discount
#      }
#    }
#
#    @discount = discount
#    @compacted_value    = model_states.map {|state| value[state]}
#    if policy.empty?
#      # default to the first action, arbitrarily
#      @compacted_policy = [0]*n
#    else
#      # actions are numbered per-state
#      action_to_num = model_states.map{|state|
#        actions = model.actions(state)
#        Hash[actions.zip(0...actions.size)]
#      }
#      @compacted_policy = action_to_num.zip(model_states).
#        map {|a_to_n, state| a_to_n[policy[state]]}
#    end
#
#    raise 'some initial values are missing' if
#      @compacted_value.any? {|v| v.nil?}
#    raise 'some initial policy actions are missing' if
#      @compacted_policy.any? {|a| a.nil?}
#  end
#
#  #
#  # Obtain exact values for the current policy.
#  #
#  # The Bellman equations are a linear system when the policy is held fixed;
#  # this method solves the system. 
#  # 
#  def evaluate_policy
#    a = NMatrix.float(n,n)
#    z = NVector.float(n)
#    v = 
#
#  end
#end

