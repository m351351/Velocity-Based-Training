<?php
require_once 'config.php';
header("Access-Control-Allow-Origin: *");
header('Content-Type: application/json'); // Kerrotaan selaimelle/Flutterille, että tämä on JSONia

$conn = new mysqli(DB_SERVER, DB_USERNAME, DB_PASSWORD, DB_NAME);

if ($conn->connect_error) {
    die(json_encode(["error" => "Yhteys epäonnistui"]));
}

// Haetaan 50 viimeisintä riviä
$sql = "SELECT id, session_id, acc_x, acc_y, acc_z, label, created_at FROM sensor_data ORDER BY id DESC LIMIT 50";
$result = $conn->query($sql);

$rows = array();
while($r = $result->fetch_assoc()) {
    $rows[] = $r;
}

// Tulostetaan data JSON-muodossa
echo json_encode($rows);

$conn->close();
?>