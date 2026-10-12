/// Frontière réservée aux futures sources compilées dans l’application.
/// Aucun fournisseur, registre, réseau ou chargement de code externe dans le socle.
/// L’import local restera indépendant de cette abstraction.
protocol Source: Sendable {}
