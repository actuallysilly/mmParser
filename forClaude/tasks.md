# faitful UI copy of infloww

I want a faithful clone of the infloww UI
we have many use cases for it
* feature testing
* ai training lab
* shift live capture
* recording vid -> messages preview 

# repo splitting

MMA lite -> keep only the core set of features, public repo, for sharing
MMA      -> this repo along with tooling and AI 

what was originally simple and advanced mode

core features:
    main gui, parsing, multiple models, auto-detection, one click importing
    hotstring and script related functionality + ctrl+shift+o


MMA lite -> new publc repo
MMA      -> mmParser private repo 

Each would have an installer of their own that just donwloads the target repo

doable?