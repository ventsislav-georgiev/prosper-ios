/// Command-line vocabulary the English dictionary doesn't know, for the compact
/// keyboard's touch correction (`TerminalKeyboard.corrected`): tool names, their
/// subcommands, flags and resource kinds, shell keywords and file extensions.
/// Lowercase, letters only, each once. Plain English words are left to the dictionary.
///
/// Public, widely known vocabulary only: the repo is public, so names that belong to
/// one company (services, clusters, hosts) come from the terminal itself at runtime
/// (`TerminalKeyboard.screenWords`), never from here.
enum ShellWords {
    static let all: [String] = """
        fd find rg grep egrep fgrep sd sed gsed awk xargs sg astgrep jq jaq yq gron mlr dasel
        eza ls zoxide fzf bat delta difft hyperfine gh glab gitleaks tokei dust duf procs ps
        xh curl wget choose cut htmlq glow ouch zellij tmux

        git kubectl gcloud gsutil bq helm helmfile terraform tofu opentofu terragrunt docker
        podman pnpm npm npx yarn node deno bun python pip pipx uv brew xcodebuild xcrun
        simctl devicectl xcodegen swift swiftc swiftlint swiftformat ssh scp sftp rsync
        claude make cmake

        bash zsh sh fish esac elif fi printf mkdir rmdir chmod chown chgrp sudo env pwd mv cp
        rm ln wc uniq tr pkill pgrep killall lsof htop df du tar gzip gunzip unzip xz zstd
        uname whoami ulimit umask nohup disown unalias setopt mktemp basename dirname realpath
        readlink crontab launchctl systemctl journalctl sysctl plutil codesign xattr pbcopy
        pbpaste osascript mdfind hdiutil diskutil vim nvim vi emacs tig lazygit stdin stdout
        stderr tmp usr bin sbin lib opt etc dev proc argv argc shebang bashrc zshrc zprofile
        zshenv dotfiles localhost openssl ifconfig traceroute nslookup netstat ncat shasum

        rebase reflog worktree worktrees cherrypick bisect fixup autosquash autostash
        refspec revparse shortlog submodule subtree mergetool difftool gitconfig gitignore
        gitattributes gitmodules lfs gpg signoff rerere oneline porcelain untracked unstaged
        noverify noff ff upstream

        pr prs repo repos gist codespace mr mrs

        rollout statefulset statefulsets daemonset daemonsets configmap configmaps namespace
        namespaces ns ctx kubeconfig kubectx kubens replicaset replicasets cronjob cronjobs
        svc hpa pvc pv crd crds rbac clusterrole clusterrolebinding rolebinding
        serviceaccount kustomize kustomization uncordon portforward nodeport loadbalancer
        clusterip kubelet kubeadm minikube istio istioctl argocd

        gke gcs gcr iam pubsub bigquery cloudsql cloudbuild appengine kms vpc subnet subnets

        tfvars tfstate tfplan hcl tflint tfsec fmt

        dockerfile dockerignore buildx buildkit entrypoint healthcheck rmi containerd

        devdependencies peerdependencies npmrc nvmrc nvm fnm corepack tsc tsconfig eslint
        eslintrc prettierrc vite vitest webpack esbuild turborepo nx lerna nodemon monorepo
        typescript javascript lockfile postinstall preinstall dotenv babel swc

        venv virtualenv conda pytest pyenv pyproject ipython jupyter numpy pandas setuptools
        mypy ruff isort uvicorn django fastapi pydantic kwargs args isinstance stdlib

        swiftpm spm xcodeproj xcworkspace xcscheme xcconfig xctest xctrace deriveddata
        testflight fastlane cocoapods podfile uikit swiftui appkit struct enum func init
        deinit inout typealias nonisolated mainactor sendable

        println sprintf strlen malloc stdio iostream nullptr bool int uint str len impl pub fn
        mut usize rustc rustup clippy tokio serde golang goroutine gofmt

        mcp subagent subagents statusline

        nginx postgres postgresql psql mysql redis sqlite kafka rabbitmq grafana prometheus
        promql kibana elasticsearch opensearch ansible pulumi

        ipv tcp udp dns http https tls cidr wireguard

        yaml yml json jsonl toml tsx jsx ts js mjs cjs md mdx py rb rs kt html css scss csv
        tsv sql proto protobuf graphql gql tf ini cfg conf txt png jpg jpeg svg webp tgz gz
        zst plist xib xcassets ipa dmg pkg db utf ascii regex readme changelog todo fixme
        """.split(whereSeparator: \.isWhitespace).map(String.init)
}
