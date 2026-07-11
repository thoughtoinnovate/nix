alias vim = nvim

# Nushell loads vendor autoload files before config.nu. This creates Starship's
# autoload file on the first run; Starship is active from the next Nushell run.
if (which starship | is-not-empty) {
    let autoload_dir = ($nu.data-dir | path join "vendor" "autoload")
    mkdir $autoload_dir
    starship init nu | save --force ($autoload_dir | path join "starship.nu")
}

