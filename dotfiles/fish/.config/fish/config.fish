set home_weave_state_root $HOME/.local/state
if set -q XDG_STATE_HOME
    set home_weave_state_root $XDG_STATE_HOME
end
set home_weave_profile_bin $home_weave_state_root/nix/profiles/home-weave/bin
if not contains -- $home_weave_profile_bin $PATH
    set -gx PATH $home_weave_profile_bin $PATH
end
set -e home_weave_state_root home_weave_profile_bin

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
