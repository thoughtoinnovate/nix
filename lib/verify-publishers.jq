with_entries(
  (.key | split(".") | .[2:] | join(".")) as $package
  | (.value.homepage // "") as $homepage
  | (.value.provenance // []) as $provenance
  | ([
      $registry[0][]
      | select(.package == $package)
      | select(. as $rule | any($rule.homepagePrefixes[]; $homepage | startswith(.)))
      | select(. as $rule | all($rule.requiredProvenance[]; . as $required | $provenance | index($required) != null))
    ] | first // null) as $review
  | if $review == null
    then .value += {publisherVerified: false}
    else .value += {
      publisher: $review.publisher,
      publisherVerified: true,
      publisherEvidence: $review.evidence
    }
    end
)
