defmodule TaxiBeWeb.TaxiAllocationJob do
  use GenServer

  def start_link(request, name) do
    GenServer.start_link(__MODULE__, request, name: name)
  end

  def init(request) do
    Process.send(self(), :step1, [:nosuspend])
    %{
      "username" => customer,
      "booking_id" => bookingId
    } = request
    TaxiBeWeb.Endpoint.broadcast("customer:" <> customer, "booking_id", %{msg: "channel for id", bookingId: bookingId})
    {:ok, %{
      request: request,
      status: NotAccepted,
      time: Good,
      cancelstatus: Permitted,
      cancelled: NotCancelled
    }}
  end

  def handle_info(:step1, %{request: request} = state) do

    # send customer ride fare
    task = Task.async(fn ->
      compute_ride_fare(request)
      |> notify_customer_ride_fare()
    end)
    Task.await(task)

    # get all taxis
    taxis = select_candidate_taxis(request)

    %{"booking_id" => booking_id} = request

    # send out requests to all taxis
    Enum.map(taxis, fn taxi -> TaxiBeWeb.Endpoint.broadcast("driver:" <> taxi.nickname, "booking_request", %{msg: "viaje disponible", bookingId: booking_id}) end)

    Process.send_after(self(), :timelimit, 40000)
    {:noreply, state}
  end

  def handle_info(:timelimit, %{request: request, status: NotAccepted} = state) do
    %{"username" => customer} = request
    TaxiBeWeb.Endpoint.broadcast("customer:" <> customer, "booking_request", %{msg: "A problem looking for a driver has arisen"})
    {:noreply, %{state | time: Exceeded}}
  end

  def handle_info(:timelimit, %{status: Accepted} = state) do

    {:noreply, %{state | time: Exceeded}}
  end

  def handle_info(:timelimit, %{cancelled: IsCancelled} = state) do

    {:noreply, %{state | time: Exceeded}}
  end

  def handle_info(:cancelbad, state) do
    # modify state to add tariff in case of cancellation
    {:noreply, %{state | cancelstatus: Tariff}}
  end

  def handle_info(:driverarrived, %{request: request, cancelled: NotCancelled} = state) do
    %{"username" => customer} = request
    TaxiBeWeb.Endpoint.broadcast("customer:" <> customer, "booking_request", %{msg: "Your taxi has arrived"})
    {:noreply, state}
  end

  def handle_info(:driverarrived, %{request: request, cancelled: IsCancelled} = state) do
    {:noreply, state}
  end

  # this is the accept function that actually links a taxi to the booking request
  # when NOT ACCEPTED and TIME GOOD

  def handle_cast({:process_accept, driver_username}, %{request: request, status: NotAccepted, time: Good, cancelled: NotCancelled} = state) do
    # send out eventual arrival
    Process.send_after(self(), :driverarrived, 40000)

    # notify customer that driver is on the way
    %{"username" => customer} = request
    taxis = select_candidate_taxis(request)
    taxi = getTaxi(driver_username, taxis)
    %{"pickup_address" => pickup_address} = request
    arrival = compute_estimated_arrival(pickup_address, taxi)
    # IO.inspect(arrival/60)

    TaxiBeWeb.Endpoint.broadcast("customer:" <> customer, "booking_request", %{msg: "Driver #{driver_username} on the way, in #{round(Float.floor(arrival/60, 0))} minutes and #{rem(round(arrival), 60)} seconds"})

    # prepare state for possible cancellation
    Process.send_after(self(), :cancelbad, 20000)
    {:noreply, %{state | status: Accepted}}
  end

  # When ACCEPTED

  def handle_cast({:process_accept, driver_username}, %{status: Accepted} = state) do
    TaxiBeWeb.Endpoint.broadcast("driver:" <> driver_username, "booking_notification", %{msg: "Already taken"})
    {:noreply, state}
  end

  # NT ACCEPTED but TIME EXCEEDED
  def handle_cast({:process_accept, driver_username}, %{time: Exceeded} = state) do
    TaxiBeWeb.Endpoint.broadcast("driver:" <> driver_username, "booking_notification", %{msg: "Too late homie"})
    {:noreply, state}
  end

  # WHEN RIDE CANCELLED
  def handle_cast({:process_accept, driver_username}, %{cancelled: IsCancelled} = state) do
    TaxiBeWeb.Endpoint.broadcast("driver:" <> driver_username, "booking_notification", %{msg: "User Cancelled"})
    {:noreply, state}
  end

  def handle_cast({:process_reject, driver_username}, state) do
    {:noreply, state}
  end

  # cancel cast if cancelling is permitted
  def handle_cast({:process_cancel, customer_username}, %{request: request, cancelstatus: Permitted} = state) do
    IO.inspect(state)
    TaxiBeWeb.Endpoint.broadcast("customer:" <> customer_username, "booking_request", %{msg: "Cancelled successfully"})

    {:noreply, %{state | cancelled: IsCancelled}}
  end

  # cancel cast if cancelling is not permitted
  def handle_cast({:process_cancel, customer_username}, %{request: request, cancelstatus: Tariff} = state) do
    TaxiBeWeb.Endpoint.broadcast("customer:" <> customer_username, "booking_request", %{msg: "A tariff will be added to your bill"})
    {:noreply, state}
  end

  def compute_ride_fare(request) do
    %{
      "pickup_address" => pickup_address,
      "dropoff_address" => dropoff_address
     } = request

    coord1 = TaxiBeWeb.Geolocator.geocode(pickup_address)
    coord2 = TaxiBeWeb.Geolocator.geocode(dropoff_address)
    IO.inspect(coord1)
    {distance, _duration} = TaxiBeWeb.Geolocator.distance_and_duration(coord1, coord2)
    {request, Float.ceil(distance/300)}
  end

  def notify_customer_ride_fare({request, fare}) do
    %{"username" => customer} = request
    TaxiBeWeb.Endpoint.broadcast("customer:" <> customer, "booking_request", %{msg: "Ride fare: #{fare}"})
  end

  def compute_estimated_arrival(pickup_address, taxi) do
    coord1 = {:ok, [taxi.longitude, taxi.latitude]}
    coord2 = TaxiBeWeb.Geolocator.geocode(pickup_address)
    {_distance, duration} = TaxiBeWeb.Geolocator.distance_and_duration(coord1, coord2)
    duration
  end

  def select_candidate_taxis(%{"pickup_address" => _pickup_address}) do
    [
      %{nickname: "frodo", latitude: 19.0319783, longitude: -98.2349368}, # Angelopolis
      %{nickname: "samwise", latitude: 19.0061167, longitude: -98.2697737}, # Arcangeles
      %{nickname: "merry", latitude: 19.0092933, longitude: -98.2473716} # Paseo Destino
    ]
  end

  def getTaxi(taxi_name, [taxi | rest]) do
    if taxi.nickname == taxi_name do
      taxi
    else
      getTaxi(taxi_name, rest)
    end
  end

  def getTaxi(_taxi_name, []) do
    []
  end
end
