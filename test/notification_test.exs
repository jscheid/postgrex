defmodule NotificationTest do
  use ExUnit.Case, async: true
  import Postgrex.TestHelper
  alias Postgrex, as: P
  alias Postgrex.Notifications, as: PN

  @opts [database: "postgrex_test", sync_connect: true]

  setup do
    {:ok, pid} = P.start_link(@opts)
    {:ok, pid_ps} = PN.start_link(@opts)
    {:ok, [pid: pid, pid_ps: pid_ps]}
  end

  test "fails on sync connection by default" do
    Process.flag(:trap_exit, true)
    assert {:error, _} = PN.start_link(database: "nobody_knows_it")
  end

  test "does not fail on sync connection with auto reconnect" do
    Process.flag(:trap_exit, true)
    assert {:ok, pid} = PN.start_link(database: "nobody_knows_it", auto_reconnect: true)
    assert {:eventually, _} = PN.listen(pid, "channel")
  end

  test "does not fail on async connection with auto reconnect" do
    Process.flag(:trap_exit, true)

    assert {:ok, pid} =
             PN.start_link(database: "nobody_knows_it", auto_reconnect: true, sync_connect: false)

    assert {:eventually, _} = PN.listen(pid, "channel")
    refute_receive {:EXIT, _, ^pid}, 100
  end

  test "listening", context do
    assert {:ok, _} = PN.listen(context.pid_ps, "channel")
  end

  test "notifying", context do
    assert :ok = query("NOTIFY channel", [])
  end

  @tag requires_notify_payload: true
  test "listening, notify, then receive (with payload)", context do
    assert {:ok, ref} = PN.listen(context.pid_ps, "channel")

    assert {:ok, %Postgrex.Result{command: :notify}} =
             P.query(context.pid, "NOTIFY channel, 'hello'", [])

    receiver_pid = context.pid_ps
    assert_receive {:notification, ^receiver_pid, ^ref, "channel", "hello"}
  end

  test "listening, notify, then receive (without payload)", context do
    assert {:ok, ref} = PN.listen(context.pid_ps, "channel")

    assert {:ok, %Postgrex.Result{command: :notify}} = P.query(context.pid, "NOTIFY channel", [])
    receiver_pid = context.pid_ps
    assert_receive {:notification, ^receiver_pid, ^ref, "channel", ""}
  end

  test "listening, notify, then receive (using registered names)", _context do
    {:ok, _} = P.start_link(Keyword.put(@opts, :name, :client))
    {:ok, _} = PN.start_link(Keyword.put(@opts, :name, :notifications))
    assert {:ok, ref} = PN.listen(:notifications, "channel")

    assert {:ok, %Postgrex.Result{command: :notify}} = P.query(:client, "NOTIFY channel", [])
    receiver_pid = Process.whereis(:notifications)
    assert_receive {:notification, ^receiver_pid, ^ref, "channel", ""}
  end

  test "listening, unlistening, notify, don't receive", context do
    assert {:ok, ref} = PN.listen(context.pid_ps, "channel")
    assert :ok = PN.unlisten(context.pid_ps, ref)

    assert {:ok, %Postgrex.Result{command: :notify}} = P.query(context.pid, "NOTIFY channel", [])
    pid = context.pid_ps
    refute_receive {:notification, ^pid, ^ref, "channel", ""}
  end

  test "listening x2, unlistening, notify, receive", context do
    {:ok, other_pid_ps} = PN.start_link(@opts)

    assert {:ok, ref1} = PN.listen(context.pid_ps, "channel")
    assert {:ok, ref2} = PN.listen(other_pid_ps, "channel")

    assert :ok = PN.unlisten(other_pid_ps, ref2)
    assert {:ok, %Postgrex.Result{command: :notify}} = P.query(context.pid, "NOTIFY channel", [])

    pid = context.pid_ps
    assert_receive {:notification, ^pid, ^ref1, "channel", ""}, 1_000
  end

  test "listen, go away", context do
    spawn(fn ->
      assert {:ok, _} = PN.listen(context.pid_ps, "channel")
    end)

    assert {:ok, %Postgrex.Result{command: :notify}} = P.query(context.pid, "NOTIFY channel", [])
    :timer.sleep(300)
  end

  describe "reconnection" do
    setup do
      {:ok, pid_ps} = PN.start_link(Keyword.put(@opts, :auto_reconnect, true))
      {:ok, pid_ps: pid_ps}
    end

    test "basic reconnection", context do
      assert {:ok, ref} = PN.listen(context.pid_ps, "channel")

      {:gen_tcp, sock} = :sys.get_state(context.pid_ps).mod_state.protocol.sock
      :gen_tcp.shutdown(sock, :read_write)
      # Give the notifier a chance to re-establish the connection and listeners
      :timer.sleep(500)

      assert {:ok, %Postgrex.Result{command: :notify}} =
               P.query(context.pid, "NOTIFY channel", [])

      receiver_pid = context.pid_ps
      assert_receive {:notification, ^receiver_pid, ^ref, "channel", ""}
    end

    test "reestablish multiple listeners and channels", context do
      receiver_pid = context.pid_ps

      assert {:ok, ref} = PN.listen(context.pid_ps, "channel")

      async =
        Task.async(fn ->
          assert {:ok, ref3} = PN.listen(context.pid_ps, "channel")
          assert_receive {:notification, ^receiver_pid, ^ref3, "channel", ""}
        end)

      {:gen_tcp, sock} = :sys.get_state(context.pid_ps).mod_state.protocol.sock
      :gen_tcp.shutdown(sock, :read_write)

      # Also attempt to subscribe while it is down
      assert {ok_or_eventually, ref2} = PN.listen(context.pid_ps, "channel2")
      assert ok_or_eventually in [:ok, :eventually]

      # Give the notifier a chance to re-establish the connection and listeners
      Process.sleep(500)

      assert {:ok, %Postgrex.Result{command: :notify}} =
               P.query(context.pid, "NOTIFY channel", [])

      assert_receive {:notification, ^receiver_pid, ^ref, "channel", ""}

      assert {:ok, %Postgrex.Result{command: :notify}} =
               P.query(context.pid, "NOTIFY channel2", [])

      assert_receive {:notification, ^receiver_pid, ^ref2, "channel2", ""}

      assert Task.await(async)
    end
  end
end
