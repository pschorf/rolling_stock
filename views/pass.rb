require './views/base'

module Views
  class Pass < Base
    needs :game
    needs :current_player

    def content
      entities = game
        .active_entities
        .select { |e| e.owned_by?(current_player) && !game.passes.include?(e) }
        .reject { |e| e.respond_to?(:pending_closure?) && e.pending_closure?(game.phase, game.ownership_tier) }

      return if entities.empty?
      solo = entities.size == 1
      can_act = game.can_act? current_player

      pass_text =
        if can_act
          if solo
            game.current_bid ? 'Leave auction' : 'Pass your turn'
          else
            'Select entities to pass'
          end
        else
          solo ? 'Pass your turn early' : 'Select entities to pass early'
        end

      div pass_text

      render_js

      game_form do
        entities.each do |entity|
          pass_props = {
            name: data(entity.type),
            value: entity.id,
            onclick: 'Pass.onClick(this)',
          }

          if solo
            pass_props[:type] = 'hidden'
          else
            pass_props[:type] = 'checkbox'
            pass_props[:checked] = 'true'
          end

          div do
            input pass_props
            input type: 'hidden', name: data('action'), value: 'pass'
            label(style: inline(margin_right: '5px')) { text entity.name } unless solo
          end
        end

        submit_props = {
          type: 'submit',
          value: can_act ? 'Pass' : 'Pass Out Of Order',
        }

        div do
          input submit_props
        end
      end
    end

    def render_js
      script <<~JS
        var Pass = {
          onClick: function(el) {
            $(el).next().attr('disabled', !el.checked);
          }
        }
      JS
    end
  end

end
