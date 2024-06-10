// import React, {useEffect, useState, useMemo} from 'react';
// import Button from '@mui/material/Button'

// import socket from '../services/taxi_socket';
// import { TextField } from '@mui/material';

// function Customer(props) {
//   let [pickupAddress, setPickupAddress] = useState("Tecnologico de Monterrey, campus Puebla, Mexico");
//   let [dropOffAddress, setDropOffAddress] = useState("Triangulo Las Animas, Puebla, Mexico");
//   let [msg, setMsg] = useState("");
//   let [bookingId, setBookingId] = useState();

//   useMemo(() => {
//     console.log(msg)
//   }, [msg])

//   useEffect(() => {
//     let channel = socket.channel("customer:" + props.username, {token: "123"});
//     channel.on("greetings", data => console.log(data));
//     channel.on("booking_request", data => {
//       console.log("Received", data);
//       setMsg(data.msg);
//     });
//     channel.join();
//   },[props]);

//   let submit = () => {
//     fetch(`http://localhost:4000/api/bookings`, {
//       method: 'POST',
//       headers: {'Content-Type': 'application/json'},
//       body: JSON.stringify({pickup_address: pickupAddress, dropoff_address: dropOffAddress, username: props.username})
//     }).then(resp => resp.json()).then(data => {
//       console.log(data)
//       setMsg(data.msg)
//       setBookingId(data.bookingId)
//     });
//   };

//   let cancel = (decision) => {
//     fetch(`http://localhost:4000/api/bookings/${bookingId}`, {
//       method: 'POST',
//       headers: {'Content-Type': 'application/json'},
//       body: JSON.stringify({action: "cancel", username: props.username})
//     });
//   };


//   return (
//     <div style={{textAlign: "center", borderStyle: "solid"}}>
//       Customer: {props.username}
//       <div>
//           <TextField id="outlined-basic" label="Pickup address"
//             fullWidth
//             onChange={ev => setPickupAddress(ev.target.value)}
//             value={pickupAddress}/>
//           <TextField id="outlined-basic" label="Drop off address"
//             fullWidth
//             onChange={ev => setDropOffAddress(ev.target.value)}
//             value={dropOffAddress}/>
//         <Button onClick={submit} variant="outlined" color="primary">Submit</Button>
//         <Button onClick={cancel} variant="outlined" color="primary">Cancel</Button>
//       </div>
//       <div style={{backgroundColor: "lightcyan", height: "50px"}}>
//         {msg}
//       </div>
//     </div>
//   );
// }

// export default Customer;



import React, {useEffect, useState} from 'react';
import Button from '@mui/material/Button'

import socket from '../services/taxi_socket';
import { TextField } from '@mui/material';

function Customer(props) {
  let [pickupAddress, setPickupAddress] = useState("Tecnologico de Monterrey, campus Puebla, Mexico");
  let [dropOffAddress, setDropOffAddress] = useState("Triangulo Las Animas, Puebla, Mexico");
  let [msg, setMsg] = useState("");
  let [bookingId, setBookingId] = useState();

  useEffect(() => {
    let channel = socket.channel("customer:" + props.username, {token: "123"});
    channel.on("greetings", data => console.log(data));
    channel.on("booking_id", data => {
      console.log("booking id", data)
      setBookingId(data.bookingId)
    })
    channel.on("booking_request", data => {
      console.log("Received", data);
      setMsg(data.msg);
    });
    channel.join();
  },[props]);

  let submit = () => {
    fetch(`http://localhost:4000/api/bookings`, {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({pickup_address: pickupAddress, dropoff_address: dropOffAddress, username: props.username})
    }).then(resp => resp.json()).then(data => {
      console.log(data)
      setMsg(data.msg); 
      // setBookingId(data.bookingId);
    });
  };

  let cancel = (decision) => {
    fetch(`http://localhost:4000/api/bookings/${bookingId}`, {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({action: "cancel", username: props.username})
    });
  };


  return (
    <div style={{textAlign: "center", borderStyle: "solid"}}>
      Customer: {props.username}
      <div>
          <TextField id="outlined-basic" label="Pickup address"
            fullWidth
            onChange={ev => setPickupAddress(ev.target.value)}
            value={pickupAddress}/>
          <TextField id="outlined-basic" label="Drop off address"
            fullWidth
            onChange={ev => setDropOffAddress(ev.target.value)}
            value={dropOffAddress}/>
        <Button onClick={submit} variant="outlined" color="primary">Submit</Button>
        <Button onClick={cancel} variant="outlined" color="primary">Cancel</Button>
      </div>
      <div style={{backgroundColor: "lightcyan", height: "50px"}}>
        {msg}
      </div>
    </div>
  );
}

export default Customer;

