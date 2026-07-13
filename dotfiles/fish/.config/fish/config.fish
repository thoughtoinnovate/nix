set -gx EDITOR nvim
set -gx VISUAL nvim

alias vim nvim

if type -q home-weave-env
    command home-weave-env render fish \
        "$HOME/.home_weave_profile" "$HOME/.home_weave_secrets" | source
    if not test $pipestatus[1] -eq 0
        echo 'HomeWeave environment was not loaded; review the error above.' >&2
    end
end

if type -q starship
    starship init fish | source
end
