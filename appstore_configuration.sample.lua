-- User-editable configuration for AppStore plugin.
-- Fill in your personal access tokens (PAT) here to raise API limits.
-- Example for GitHub: generate a PAT with "public_repo" scope and paste it below.
return {
    auth = {
        github = {
            type = "github",
            token = "your_github_token",
        },
    },
}

