let home_weave_brew_candidates = (
  ["/opt/homebrew/bin/brew" "/usr/local/bin/brew"]
  | where {|candidate| $candidate | path exists }
)
let home_weave_brew = if ($home_weave_brew_candidates | is-empty) {
  null
} else {
  $home_weave_brew_candidates | first
}
if ($home_weave_brew | is-not-empty) {
    let home_weave_brew_prefix = (do -i { ^$home_weave_brew --prefix } | str trim)
    if ($home_weave_brew_prefix | is-not-empty) {
        $env.HOMEBREW_PREFIX = $home_weave_brew_prefix
        $env.HOMEBREW_CELLAR = ($home_weave_brew_prefix | path join "Cellar")
        $env.HOMEBREW_REPOSITORY = ($home_weave_brew_prefix | path join "Homebrew")
        let home_weave_brew_bin = ($home_weave_brew_prefix | path join "bin")
        let home_weave_brew_sbin = ($home_weave_brew_prefix | path join "sbin")
        if not ($home_weave_brew_bin in $env.PATH) {
            $env.PATH = ($env.PATH | append $home_weave_brew_bin)
        }
        if not ($home_weave_brew_sbin in $env.PATH) {
            $env.PATH = ($env.PATH | append $home_weave_brew_sbin)
        }
    }
}

let home_weave_local_bin = ($env.HOME | path join ".local" "bin")
if not ($home_weave_local_bin in $env.PATH) {
    $env.PATH = ($env.PATH | prepend $home_weave_local_bin)
}

let home_weave_state_root = ($env.XDG_STATE_HOME? | default ($env.HOME | path join ".local" "state"))
let home_weave_profile_bin = ($home_weave_state_root | path join "nix" "profiles" "home-weave" "bin")
if not ($home_weave_profile_bin in $env.PATH) {
    $env.PATH = ($env.PATH | prepend $home_weave_profile_bin)
}

$env.EDITOR = "nvim"
$env.VISUAL = "nvim"
