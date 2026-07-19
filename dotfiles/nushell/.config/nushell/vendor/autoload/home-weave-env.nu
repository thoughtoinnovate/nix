# Load HomeWeave's shell-neutral non-secret profile and optional local secrets.
if (which home-weave-env | is-not-empty) {
    let result = (^home-weave-env render json \
        ($nu.home-dir | path join '.home_weave_profile') \
        ($nu.home-dir | path join '.home_weave_secrets') | complete)
    if $result.exit_code == 0 {
        load-env ($result.stdout | from json)
    } else {
        print --stderr $result.stderr
        print --stderr 'HomeWeave environment was not loaded; review the error above.'
    }
}
