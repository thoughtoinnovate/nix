set -gx EDITOR nvim
set -gx VISUAL nvim

alias vim nvim

if type -q starship
    starship init fish | source
end

