{:ok, _pid} = DomovoyCore.Test.Tables.start_link([])
ExUnit.start()
Application.ensure_all_started(:telemetry)
