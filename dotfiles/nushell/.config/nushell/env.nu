let home_weave_state_root = ($env.XDG_STATE_HOME? | default ($env.HOME | path join ".local" "state"))
let home_weave_profile_bin = ($home_weave_state_root | path join "nix" "profiles" "home-weave" "bin")
if not ($home_weave_profile_bin in $env.PATH) {
    $env.PATH = ($env.PATH | prepend $home_weave_profile_bin)
}

$env.EDITOR = "nvim"
$env.VISUAL = "nvim"

