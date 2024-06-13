defmodule TaxiBeWeb.TaxiAllocationJob do
  use GenServer
  # el conductor siempre llegara al minuto del accept por parte el mismo, esto para evitar tiempos largos
  #  de pruebas
  
  # los conductores tienen 30 segundos para aceptar request del cliente

  # mientras no hayan pasado los 30 segundos y un conductor no haya aceptado,
  # el cliente puede cancelar sin tarifa

  # si un conductor ya acepto, el cliente tiene 30 segundos para cancelar sin tarifa
  # de lo contrario se le enviara mensaje de que una tarifa se cobro

  # en el momento que el cliente cancela tambien se le manda la notificacion al conductor que acepto

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

    # iniciar estado con cada situacion
    {:ok, %{
      request: request,
      status: NotAccepted,
      time: Good,
      cancelstatus: Permitted,
      cancelled: NotCancelled
    }}
  end

  def handle_info(:step1, %{request: request} = state) do

    # contactar cliente
    task = Task.async(fn ->
      compute_ride_fare(request)
      |> notify_customer_ride_fare()
    end)
    Task.await(task)

    # obtener todos los taxis
    taxis = select_candidate_taxis(request)

    %{"booking_id" => booking_id} = request

    # enviar request a cada taxi
    Enum.map(taxis, fn taxi -> TaxiBeWeb.Endpoint.broadcast("driver:" <> taxi.nickname, "booking_request", %{msg: "viaje disponible", bookingId: booking_id}) end)

    # enviar llamar funcion de limite de tiempo en un minuto
    Process.send_after(self(), :timelimit, 30000)
    {:noreply, state}
  end

  # limite de tiempo, status: NotAccepted
  def handle_info(:timelimit, %{request: request, status: NotAccepted, cancelled: NotCancelled} = state) do
    # Enviar mensaje de problema a cliente
    %{"username" => customer} = request
    TaxiBeWeb.Endpoint.broadcast("customer:" <> customer, "booking_request", %{msg: "A problem looking for a driver has arisen"})

    # editar estado para tiempo excedido
    {:noreply, %{state | time: Exceeded}}
  end

  # limite de tiempo, status: Accepted
  def handle_info(:timelimit, %{status: Accepted} = state) do
    # solo editar estado para reflejar tiempo excedido
    {:noreply, %{state | time: Exceeded}}
  end

  # limite de tiempo, status: Accepted
  def handle_info(:timelimit, %{cancelled: IsCancelled, status: NotAccepted} = state) do
    # solo editar estado para reflejar tiempo excedido
    {:noreply, %{state | time: Exceeded}}
  end

  # editar estado para reflejar que la cancelacion agregara una tarifa
  def handle_info(:cancelbad, state) do
    # enviar mensaje de tarifa y modificar estado
    {:noreply, %{state | cancelstatus: Tariff}}
  end

  #  handles para llegada de conductor, casos cancelled y notcancelled
  def handle_info(:driverarrived, %{request: request, cancelled: NotCancelled} = state) do
    %{"username" => customer} = request
    %{:driver => driver} = state
    TaxiBeWeb.Endpoint.broadcast("customer:" <> customer, "driver_arrival", %{msg: "Your taxi has arrived"})
    TaxiBeWeb.Endpoint.broadcast("driver:" <> driver, "booking_notification", %{msg: "You have arrived"})
    {:noreply, state}
  end

  def handle_info(:driverarrived, %{request: request, cancelled: IsCancelled} = state) do
    {:noreply, state}
  end

  # accept en caso de buen tiempo, no cancelado y no aun aceptado
  def handle_cast({:process_accept, driver_username}, %{request: request, status: NotAccepted, time: Good, cancelled: NotCancelled} = state) do
    # send out eventual arrival
    Process.send_after(self(), :driverarrived, 60000)

    # notify customer that driver is on the way
    %{"username" => customer} = request
    taxis = select_candidate_taxis(request)
    taxi = getTaxi(driver_username, taxis)
    %{"pickup_address" => pickup_address} = request
    arrival = compute_estimated_arrival(pickup_address, taxi)

    TaxiBeWeb.Endpoint.broadcast("customer:" <> customer, "booking_request", %{msg: "Driver #{driver_username} on the way, in #{round(Float.floor(arrival/60, 0))} minutes and #{rem(round(arrival), 60)} seconds"})

    # prepare state for possible cancellation, 20 seconds to respond
    Process.send_after(self(), :cancelbad, 30000)
    state = state |> Map.put(:driver, driver_username)
    {:noreply, %{state | status: Accepted}}
  end

  # When ACCEPTED
  def handle_cast({:process_accept, driver_username}, %{status: Accepted, cancelled: NotCancelled} = state) do
    TaxiBeWeb.Endpoint.broadcast("driver:" <> driver_username, "booking_notification", %{msg: "Already taken"})
    {:noreply, state}
  end

  def handle_cast({:process_accept, driver_username}, %{status: Accepted, cancelled: IsCancelled} = state) do
    TaxiBeWeb.Endpoint.broadcast("driver:" <> driver_username, "booking_notification", %{msg: "User cancelled"})
    {:noreply, state}
  end

  # NOT ACCEPTED but TIME EXCEEDED
  def handle_cast({:process_accept, driver_username}, %{time: Exceeded} = state) do
    TaxiBeWeb.Endpoint.broadcast("driver:" <> driver_username, "booking_notification", %{msg: "Aceptacion muy tarde"})
    {:noreply, state}
  end

  # WHEN RIDE CANCELLED
  def handle_cast({:process_accept, driver_username}, %{cancelled: IsCancelled} = state) do
    TaxiBeWeb.Endpoint.broadcast("driver:" <> driver_username, "booking_notification", %{msg: "User Cancelled"})
    {:noreply, state}
  end

  # en caso de rechazo, solo regresar estado
  def handle_cast({:process_reject, driver_username}, state) do
    {:noreply, state}
  end

  # cancel cast if cancelling is permitted
  def handle_cast({:process_cancel, customer_username}, %{request: request, cancelstatus: Permitted, status: NotAccepted} = state) do
    IO.inspect(state)
    TaxiBeWeb.Endpoint.broadcast("customer:" <> customer_username, "driver_arrival", %{msg: "Cancelled successfully"})

    {:noreply, %{state | cancelled: IsCancelled}}
  end

  def handle_cast({:process_cancel, customer_username}, %{request: request, cancelstatus: Permitted, status: Accepted} = state) do
    IO.inspect(state)

    %{:driver => driver} = state
    TaxiBeWeb.Endpoint.broadcast("customer:" <> customer_username, "driver_arrival", %{msg: "Cancelled successfully"})
    TaxiBeWeb.Endpoint.broadcast("driver:" <> driver, "booking_notification", %{msg: "user cancelled"})
    {:noreply, %{state | cancelled: IsCancelled}}
  end

  # cancel cast if cancelling is not permitted
  def handle_cast({:process_cancel, customer_username}, %{request: request, cancelstatus: Tariff} = state) do
    %{:driver => driver} = state
    TaxiBeWeb.Endpoint.broadcast("customer:" <> customer_username, "driver_arrival", %{msg: "Late cancelation charge: $1,000,000"})
    TaxiBeWeb.Endpoint.broadcast("driver:" <> driver, "booking_notification", %{msg: "user cancelled, tip was charged"})
    {:noreply, %{state | cancelled: IsCancelled}}
  end


  #funciones auxiliares
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
