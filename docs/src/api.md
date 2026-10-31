```@meta
CurrentModule = SlackClaw
```

# API Reference

## Index

```@index
```

## Chat child and fleet control

```@autodocs
Modules = [SlackClaw]
Filter = obj -> any(name -> isdefined(SlackClaw, name) && obj === getfield(SlackClaw, name), (:run_chat_child, :chat_child_main, :FleetControl, :quiesce!, :quiesce_report, :wait_quiesced))
```

## Other docstrings

```@autodocs
Modules = [SlackClaw]
Filter = obj -> !any(name -> isdefined(SlackClaw, name) && obj === getfield(SlackClaw, name), (:run_chat_child, :chat_child_main, :FleetControl, :quiesce!, :quiesce_report, :wait_quiesced))
```
