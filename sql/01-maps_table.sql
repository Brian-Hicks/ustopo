BEGIN TRANSACTION;

  CREATE TABLE "maps" (
    `CID` INTEGER NOT NULL,
    `MapName` TEXT NOT NULL,
    `MapYear` INTEGER,
    `State` TEXT NOT NULL,
    `Datum` TEXT,
    `North` NUMERIC NOT NULL,
    `West` NUMERIC NOT NULL,
    `South` NUMERIC NOT NULL,
    `East` NUMERIC NOT NULL,
    `GeoPDF` TEXT NOT NULL,
    `Thumbnail` TEXT,
    `ItemID` INTEGER NOT NULL UNIQUE,
    `CreatedOn` TEXT,
    `FileSize` INTEGER,
    `GridSize` TEXT
  );

  -- Create indexes for map name and cell ID
  CREATE INDEX `__map_name_idx` ON `maps` (`MapName` ASC);
  CREATE INDEX `__cell_id_idx` ON `maps` (`CID` );

  PRAGMA user_version=1;

COMMIT;
