<?php
require_once 'config.php';
$conn = new mysqli(DB_SERVER, DB_USERNAME, DB_PASSWORD, DB_NAME);


if ($conn->connect_error) {
    die("Yhteys epäonnistui: " . $conn->connect_error);
}

// Luetaan saapuva JSON-data
$json = file_get_contents('php://input');
$data = json_decode($json, true);

if ($data) {
    $stmt = $conn->prepare("INSERT INTO sensor_data (session_id, acc_x, acc_y, acc_z, gyro_x, gyro_y, gyro_z, label) VALUES (?, ?, ?, ?, ?, ?, ?, ?)");
    
    // Bindataan parametrit (s = string, d = double/float)
    $stmt->bind_param("sdddddds", 
        $data['session_id'], 
        $data['acc_x'], $data['acc_y'], $data['acc_z'], 
        $data['gyro_x'], $data['gyro_y'], $data['gyro_z'], 
        $data['label']
    );

    if ($stmt->execute()) {
        echo "Data tallennettu onnistuneesti";
    } else {
        echo "Virhe tallennuksessa: " . $stmt->error;
    }
    $stmt->close();
} else {
    echo "Ei kelvollista dataa vastaanotettu";
}

$conn->close();
?>